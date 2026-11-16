import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).parent
SCRIPT = HERE / 'watchman_local_metrics.sh'


class LocalMetricsTests(unittest.TestCase):
    """Bash collector with fake nvidia-smi/docker on PATH; never touches real GPU or Docker."""

    def run_collector(self, meminfo=None, nvidia=None, docker=None):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            for name, body in (('nvidia-smi', nvidia), ('docker', docker)):
                # Absent tool -> stub that fails, so the host's real tools are never used.
                tool = bin_dir / name
                tool.write_text('#!/bin/sh\n' + (body if body is not None else 'exit 127\n'))
                tool.chmod(0o755)
            mem = root / 'meminfo'
            if meminfo is not None:
                mem.write_text(meminfo)
            env = dict(os.environ, PATH=str(bin_dir) + ':' + os.environ['PATH'], WATCHMAN_MEMINFO=str(mem))
            r = subprocess.run(['bash', str(SCRIPT)], env=env, text=True, capture_output=True, timeout=10)
            self.assertEqual(r.returncode, 0, r.stderr)
            return json.loads(r.stdout)

    def test_memory_calculation(self):
        self.assertEqual(self.run_collector('MemTotal: 1000 kB\nMemAvailable: 250 kB\n')['memory']['percent'], 75)

    def test_missing_memory(self):
        self.assertIsNone(self.run_collector('MemTotal: 1000 kB\n')['memory']['percent'])
        self.assertIsNone(self.run_collector('MemTotal: 0 kB\nMemAvailable: 0 kB\n')['memory']['percent'])
        self.assertIsNone(self.run_collector(None)['memory']['percent'])

    def test_gpu_and_docker_mock(self):
        r = self.run_collector('MemTotal: 1000 kB\nMemAvailable: 500 kB\n',
                               nvidia='printf "0, 52, 19, 300, 8192, GPU-aaaa-1111, 00000000:01:00.0, NVIDIA GeForce RTX 2060\\n1, 41, 3, 10, 12288, GPU-bbbb-2222, 00000000:02:00.0, NVIDIA GeForce RTX 3060\\n"\n',
                               docker='printf "ollama\\trunning\\nimmich\\texited\\n"\n')
        self.assertEqual(r['memory']['percent'], 50)
        self.assertEqual(r['gpu'], {'available': True, 'temperature_c': 52, 'utilization_percent': 19,
                                    'memory_used_mb': 300, 'memory_total_mb': 8192})
        self.assertEqual([(g['index'], g['name'], g['temperature_c']) for g in r['gpus']],
                         [(0, 'NVIDIA GeForce RTX 2060', 52), (1, 'NVIDIA GeForce RTX 3060', 41)])
        self.assertEqual(r['gpus'][1]['uuid'], 'GPU-bbbb-2222')
        self.assertEqual(r['gpus'][1]['bus_id'], '00000000:02:00.0')
        self.assertEqual(r['gpu_query'], 'ok')
        self.assertNotIn('uuid', r['gpu'])
        self.assertEqual(r['docker']['containers'],
                         [{'name': 'ollama', 'status': 'running'}, {'name': 'immich', 'status': 'exited'}])
        self.assertEqual(r['source'], 'watchman-local-readonly')

    def test_multi_gpu_written_line_by_line(self):
        # Found on JohnsVault (RTX 2060 + 3060): nvidia-smi writes one row per GPU; a reader that
        # closes the pipe after row 1 made nvidia-smi fail under pipefail and the GPU read "unavailable".
        r = self.run_collector('MemTotal: 1000 kB\nMemAvailable: 500 kB\n',
                               nvidia='echo "0, 42, 0, 33, 12288, GPU-aaaa-1111, 00000000:01:00.0, NVIDIA GeForce RTX 2060"\nsleep 0.3\necho "1, 46, 0, 33, 12288, GPU-bbbb-2222, 00000000:02:00.0, NVIDIA GeForce RTX 3060"\n')
        self.assertTrue(r['gpu']['available'], r['gpu'])
        self.assertEqual(r['gpu']['temperature_c'], 42)
        self.assertEqual([g['temperature_c'] for g in r['gpus']], [42, 46])

    def test_nvidia_620_fractional_temperatures_are_available(self):
        # Regression from the first Unraid 7.4.0 boot: nvidia-smi 620.70.06
        # emits 40.41, not the integer 40 used by older driver versions.
        r = self.run_collector('MemTotal: 1000 kB\nMemAvailable: 500 kB\n',
            nvidia='printf "0, 40.41, 0, 36, 12288, GPU-aaaa-1111, 00000000:03:00.0, NVIDIA GeForce RTX 2060\\n1, 46.31, 0, 111, 12288, GPU-bbbb-2222, 00000000:04:00.0, NVIDIA GeForce RTX 3060\\n"\n')
        self.assertEqual(r['gpu_query'], 'ok')
        self.assertEqual(r['gpu_error'], None)
        self.assertTrue(r['gpu']['available'])
        self.assertAlmostEqual(r['gpu']['temperature_c'], 40.41)
        self.assertEqual([g['available'] for g in r['gpus']], [True, True])
        self.assertEqual([g['temperature_c'] for g in r['gpus']], [40.41, 46.31])
        self.assertEqual([g['memory_used_mb'] for g in r['gpus']], [36, 111])

    def test_fractional_temperature_unknown_preserves_per_card_failure(self):
        r = self.run_collector('MemTotal: 1000 kB\nMemAvailable: 500 kB\n',
            nvidia='printf "0, 39.97, 0, 36, 12288, GPU-a, 00000000:03:00.0, RTX 2060\\n1, [N/A], 0, 111, 12288, GPU-b, 00000000:04:00.0, RTX 3060\\n"\n')
        self.assertEqual([g['available'] for g in r['gpus']], [True, False])
        self.assertAlmostEqual(r['gpus'][0]['temperature_c'], 39.97)
        self.assertNotIn('temperature_c', r['gpus'][1])

    def test_unreadable_card_kept_as_unavailable(self):
        r = self.run_collector('MemTotal: 1000 kB\nMemAvailable: 500 kB\n',
                               nvidia='echo "0, 42, 0, 33, 12288, GPU-aaaa-1111, 00000000:01:00.0, NVIDIA GeForce RTX 2060"\necho "1, [N/A], [N/A], 0, 12288, GPU-bbbb-2222, 00000000:02:00.0, NVIDIA GeForce RTX 3060"\n')
        self.assertEqual(r['gpus'][1], {'index': 1, 'name': 'NVIDIA GeForce RTX 3060', 'available': False,
                                        'uuid': 'GPU-bbbb-2222', 'bus_id': '00000000:02:00.0'})
        self.assertTrue(r['gpus'][0]['available'])

    def test_missing_tools_fail_closed(self):
        r = self.run_collector(None)
        self.assertIsNone(r['memory']['percent'])
        self.assertFalse(r['gpu']['available'])
        self.assertFalse(r['docker']['available'])

    def gpu_case(self, body):
        r = self.run_collector('MemTotal: 1000 kB\nMemAvailable: 500 kB\n', nvidia=body)
        return r['gpu_query'], r['gpu_error'], r['gpus']

    def test_gpu_query_outcomes_are_distinguished(self):
        # Query FAILED vs query SUCCEEDED with zero GPUs must not look the same.
        self.assertEqual(self.gpu_case('echo "No devices were found"\nexit 6\n'), ('none', None, []))
        self.assertEqual(self.gpu_case('exit 0\n'), ('none', None, []))
        self.assertEqual(self.gpu_case('echo "NVIDIA-SMI has failed"\nexit 9\n'),
                         ('error', 'NVIDIA driver not loaded (exit code 9)', []))
        self.assertEqual(self.gpu_case('exit 2\n'), ('error', 'exit code 2', []))
        self.assertEqual(self.gpu_case('echo garbage\n'), ('error', 'unreadable output', []))
        q = self.gpu_case('echo "0, 41, 0, 33, 12288, GPU-a, 00000000:03:00.0, RTX"\n')
        self.assertEqual((q[0], q[1], len(q[2])), ('ok', None, 1))

    def test_gpu_query_timeout_is_an_error(self):
        self.assertEqual(self.gpu_case('sleep 5\n'), ('error', 'timed out after 3 s', []))

    def test_bad_rows_fail_closed(self):
        r = self.run_collector('MemTotal: 1000 kB\nMemAvailable: 500 kB\n',
                               nvidia='echo "[N/A], 1, 2, 3"\n', docker='echo badrow\n')
        self.assertFalse(r['gpu']['available'])
        self.assertEqual(r['gpus'], [])
        self.assertEqual(r['gpu_query'], 'error')
        self.assertEqual(r['gpu_error'], 'unreadable output')
        self.assertFalse(r['docker']['available'])

    def test_no_containers_is_available_and_empty(self):
        r = self.run_collector('MemTotal: 1000 kB\nMemAvailable: 500 kB\n', docker='exit 0\n')
        self.assertEqual(r['docker'], {'available': True, 'containers': []})

    def test_no_python_dependency(self):
        self.assertNotIn('python', SCRIPT.read_text().split('\n', 4)[-1])


if __name__ == '__main__':
    unittest.main()
