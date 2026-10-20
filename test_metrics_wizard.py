import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parent
JQ = ROOT.parent / 'nas-watchman-release-candidate/.test-tools/bin'


class MetricsWizard(unittest.TestCase):
    def test_select_local_persists_and_reloads(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            script = ROOT / 'watchman.sh'
            env = dict(os.environ, WATCHMAN_CONFIG_DIR=str(root),
                       PATH=str(JQ) + ':' + os.environ['PATH'])
            # Source only the function declarations; never launch the real engine.
            body = script.read_text().split('\ncase "${1:-}" in\n')[0]
            runner = root / 'wizard.sh'
            runner.write_text(body + '\nset_metrics_mode\nload_config\nprintf "LOADED:%s\\n" "$WATCHMAN_METRICS_MODE"\n')
            first = subprocess.run(['bash', str(runner)], input='2\ny\n',
                                   text=True, capture_output=True, env=env, timeout=10)
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertIn('LOADED:local', first.stdout)
            saved = json.loads((root / 'watchman.json').read_text())
            self.assertEqual(saved['metrics_mode'], 'local')
            # Fresh shell process loads persisted choice.
            reload_script = root / 'reload.sh'
            reload_script.write_text(body + '\nload_config\nprintf "LOADED:%s\\n" "$WATCHMAN_METRICS_MODE"\n')
            again = subprocess.run(['bash', str(reload_script)], text=True,
                                   capture_output=True, env=env, timeout=10)
            self.assertEqual(again.returncode, 0, again.stderr)
            self.assertIn('LOADED:local', again.stdout)

    def test_invalid_choice_does_not_save(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            body = (ROOT / 'watchman.sh').read_text().split('\ncase "${1:-}" in\n')[0]
            runner = root / 'wizard.sh'
            runner.write_text(body + '\nset_metrics_mode\n')
            env = dict(os.environ, WATCHMAN_CONFIG_DIR=str(root),
                       PATH=str(JQ) + ':' + os.environ['PATH'])
            r = subprocess.run(['bash', str(runner)], input='9\n',
                               text=True, capture_output=True, env=env, timeout=10)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertFalse((root / 'watchman.json').exists())


if __name__ == '__main__':
    unittest.main()
