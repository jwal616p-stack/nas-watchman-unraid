import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).parent



class EngineModes(unittest.TestCase):
    def run_case(self, payload, mode='sidecar'):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            fake_curl = bin_dir / 'curl'
            fake_curl.write_text('#!/bin/sh\nwhile [ "$#" -gt 0 ]; do if [ "$1" = "-o" ]; then shift; cp "$WATCHMAN_TEST_PAYLOAD" "$1"; exit 0; fi; shift; done\nexit 1\n')
            fake_curl.chmod(0o755)
            data = root / 'payload.json'
            data.write_text(json.dumps(payload))
            engine = (HERE / 'watchman_engine.sh').read_text()
            prelude = engine.split('\ncollect || exit 1\n')[0]
            script = root / 'probe.sh'
            script.write_text(prelude + '\ncollect_disks() { :; }\ncollect\ncat "$WORK/events"\n')
            env = dict(os.environ, WATCHMAN_STATE_DIR=str(root / 'state'),
                       WATCHMAN_TEST_PAYLOAD=str(data), WATCHMAN_METRICS_MODE=mode,
                       WATCHMAN_DISKS='[]', WATCHMAN_CONTAINERS='["ollama"]',
                       PATH=str(bin_dir) + ':' + os.environ['PATH'])
            r = subprocess.run(['bash', str(script)], env=env, text=True,
                               capture_output=True, timeout=10)
            self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
            return json.loads(r.stdout)

    def test_sidecar_complete(self):
        p = {'memory': {'percent': 95}, 'gpu': {'available': True, 'temperature_c': 40},
             'docker': {'available': True, 'containers': [{'name': 'ollama', 'status': 'running'}]}}
        e = self.run_case(p)
        self.assertTrue(e['ram']['bad'])
        self.assertFalse(e['gpu']['bad'])
        self.assertFalse(e['container_ollama']['bad'])

    def test_missing_sensors_do_not_report_recovery(self):
        p = {'memory': {'percent': None}, 'gpu': {'available': False},
             'docker': {'available': False, 'containers': []}}
        e = self.run_case(p)
        self.assertNotIn('ram', e)
        self.assertNotIn('gpu', e)
        self.assertNotIn('docker', e)
        self.assertNotIn('container_ollama', e)
        self.assertFalse(e['telemetry']['bad'])

    def test_local_mode_is_default_and_uses_bundled_bash_collector(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            for name, body in (('docker', 'printf "ollama\\trunning\\n"'), ('nvidia-smi', 'exit 127'),
                               ('curl', 'echo "curl must not be used in local mode" >&2; exit 99'),
                               ('python3', 'echo "python3 must not be needed" >&2; exit 98')):
                (bin_dir / name).write_text('#!/bin/sh\n' + body + '\n')
                (bin_dir / name).chmod(0o755)
            (root / 'meminfo').write_text('MemTotal: 1000 kB\nMemAvailable: 400 kB\n')
            (root / 'watchman_local_metrics.sh').write_text((HERE / 'watchman_local_metrics.sh').read_text())
            prelude = (HERE / 'watchman_engine.sh').read_text().split('\ncollect || exit 1\n')[0]
            script = root / 'probe.sh'
            script.write_text(prelude + '\ncollect_disks() { :; }\ncollect\ncat "$WORK/events"\n')
            env = {k: v for k, v in os.environ.items() if k != 'WATCHMAN_METRICS_MODE'}
            env.update(WATCHMAN_STATE_DIR=str(root / 'state'), WATCHMAN_MEMINFO=str(root / 'meminfo'),
                       WATCHMAN_DISKS='[]', WATCHMAN_CONTAINERS='["ollama"]',
                       PATH=str(bin_dir) + ':' + os.environ['PATH'])
            r = subprocess.run(['bash', str(script)], env=env, text=True, capture_output=True, timeout=10)
            self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
            e = json.loads(r.stdout)
            self.assertFalse(e['telemetry']['bad'], e)
            self.assertIn('RAM usage 60', e['ram']['message'])
            self.assertFalse(e['container_ollama']['bad'])
            self.assertNotIn('gpu', e)

    GPUS = [{'index': 0, 'name': 'NVIDIA GeForce RTX 2060', 'available': True, 'temperature_c': 40,
             'utilization_percent': 0, 'memory_used_mb': 33, 'memory_total_mb': 12288},
            {'index': 1, 'name': 'NVIDIA GeForce RTX 3060', 'available': True, 'temperature_c': 90,
             'utilization_percent': 99, 'memory_used_mb': 9000, 'memory_total_mb': 12288}]

    def test_fractional_temperature_comparison_is_numeric(self):
        p = {'memory': {'percent': 40},
             'gpu': {'available': True, 'temperature_c': 40.41},
             'gpus': [{'index': 0, 'name': 'RTX 2060', 'available': True, 'temperature_c': 40.41},
                      {'index': 1, 'name': 'RTX 3060', 'available': True, 'temperature_c': 85.35}],
             'docker': {'available': False, 'containers': []}}
        e = self.run_case(p)
        self.assertFalse(e['gpu_0']['bad'])
        self.assertTrue(e['gpu_1']['bad'])
        self.assertIn('85.35 C', e['gpu_1']['message'])

    def test_every_gpu_gets_its_own_alert(self):
        p = {'memory': {'percent': 40}, 'gpu': {'available': True, 'temperature_c': 40}, 'gpus': self.GPUS,
             'docker': {'available': False, 'containers': []}}
        e = self.run_case(p)
        self.assertFalse(e['gpu_0']['bad'])
        self.assertTrue(e['gpu_1']['bad'])
        self.assertEqual(e['gpu_1']['message'], 'GPU 1 (NVIDIA GeForce RTX 3060) temperature 90 C (warning >= 85 C)')
        self.assertNotIn('gpu', e)

    def test_unreadable_card_alerts(self):
        gpus = [self.GPUS[0], {'index': 1, 'name': 'NVIDIA GeForce RTX 3060', 'available': False}]
        e = self.run_case({'memory': {'percent': 40}, 'gpu': {'available': True, 'temperature_c': 40},
                           'gpus': gpus, 'docker': {'available': False, 'containers': []}})
        self.assertTrue(e['gpu_1']['bad'])
        self.assertIn('reading unavailable', e['gpu_1']['message'])
        self.assertFalse(e['gpu_0']['bad'])

    def test_malformed_gpus_fails_closed(self):
        e = self.run_case({'memory': {'percent': 40}, 'gpu': {'available': False},
                           'gpus': [{'index': 'x', 'available': True}], 'docker': {'available': False, 'containers': []}})
        self.assertTrue(e['telemetry']['bad'])

    def test_report_lists_every_gpu(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            data = root / 'm.json'
            data.write_text(json.dumps({'memory': {'percent': 40}, 'gpu': {'available': True, 'temperature_c': 40},
                                        'gpus': self.GPUS, 'docker': {'available': False, 'containers': []},
                                        'disk': {'percent': None}}))
            prelude = (HERE / 'watchman_engine.sh').read_text().split('\ncollect || exit 1\n')[0]
            script = root / 'probe.sh'
            script.write_text(prelude + '\ncollect_disks() { :; }\nbash() { cat "$WATCHMAN_TEST_PAYLOAD"; }\ncollect\ncat "$WORK/report"\n')
            env = dict(os.environ, WATCHMAN_STATE_DIR=str(root / 'state'), WATCHMAN_TEST_PAYLOAD=str(data),
                       WATCHMAN_METRICS_MODE='local', WATCHMAN_DISKS='[]', WATCHMAN_CONTAINERS='[]')
            r = subprocess.run(['/bin/bash', str(script)], env=env, text=True, capture_output=True, timeout=10)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('GPU 0 (NVIDIA GeForce RTX 2060): 40 C; load 0%; VRAM 33 / 12288 MiB', r.stdout)
            self.assertIn('GPU 1 (NVIDIA GeForce RTX 3060): 90 C; load 99%; VRAM 9000 / 12288 MiB', r.stdout)
            self.assertIn('Telemetry filesystem usage: not collected', r.stdout)
            self.assertNotIn('First GPU', r.stdout)

    def test_sidecar_stopped_container(self):
        p = {'memory': {'percent': 40}, 'gpu': {'available': False},
             'docker': {'available': True, 'containers': [{'name': 'ollama', 'status': 'exited'}]}}
        e = self.run_case(p)
        self.assertTrue(e['container_ollama']['bad'])


if __name__ == '__main__':
    unittest.main()
