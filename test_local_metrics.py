import json
import subprocess
import tempfile
import unittest
from pathlib import Path
import watchman_local_metrics as m


class LocalMetricsTests(unittest.TestCase):
    def test_memory_calculation(self):
        self.assertEqual(m.memory_percent("MemTotal: 1000 kB\nMemAvailable: 250 kB\n"), 75.0)

    def test_missing_memory(self):
        self.assertIsNone(m.memory_percent("MemTotal: 1000 kB\n"))
        self.assertIsNone(m.memory_percent("MemTotal: 0 kB\nMemAvailable: 0 kB\n"))

    def test_gpu_and_docker_mock(self):
        def fake_run(args, **kwargs):
            if args[0] == "nvidia-smi":
                return subprocess.CompletedProcess(args, 0, "52, 19, 300, 8192\n", "")
            return subprocess.CompletedProcess(args, 0, "ollama\trunning\nimmich\texited\n", "")
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory) / "meminfo"
            p.write_text("MemTotal: 1000 kB\nMemAvailable: 500 kB\n")
            result = m.collect(p, fake_run)
        self.assertEqual(result["memory"]["percent"], 50)
        self.assertEqual(result["gpu"]["temperature_c"], 52)
        self.assertEqual(result["docker"]["containers"][0]["status"], "running")
        self.assertEqual(result["source"], "watchman-local-readonly")

    def test_missing_tools_fail_closed(self):
        def missing(*args, **kwargs):
            raise FileNotFoundError("unavailable")
        result = m.collect("/does-not-exist", missing)
        self.assertIsNone(result["memory"]["percent"])
        self.assertFalse(result["gpu"]["available"])
        self.assertFalse(result["docker"]["available"])

    def test_bad_docker_row(self):
        def fake_run(args, **kwargs):
            if args[0] == "docker":
                return subprocess.CompletedProcess(args, 0, "badrow\n", "")
            raise FileNotFoundError()
        self.assertFalse(m.docker_data(fake_run)["available"])


if __name__ == "__main__":
    unittest.main()
