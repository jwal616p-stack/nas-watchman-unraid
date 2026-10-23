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

    def test_sidecar_stopped_container(self):
        p = {'memory': {'percent': 40}, 'gpu': {'available': False},
             'docker': {'available': True, 'containers': [{'name': 'ollama', 'status': 'exited'}]}}
        e = self.run_case(p)
        self.assertTrue(e['container_ollama']['bad'])


if __name__ == '__main__':
    unittest.main()
