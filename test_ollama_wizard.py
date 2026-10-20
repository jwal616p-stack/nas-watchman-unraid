import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parent
JQ = ROOT.parent / 'nas-watchman-release-candidate/.test-tools/bin'


class OllamaWizard(unittest.TestCase):
    def run_wizard(self, root, input_text):
        body = (ROOT / 'watchman.sh').read_text().split('\ncase "${1:-}" in\n')[0]
        script = root / 'test.sh'
        script.write_text(body + '\nset_ollama_model\nload_config\nprintf "MODEL:%s\\n" "$WATCHMAN_OLLAMA_MODEL"\n')
        env = dict(os.environ, WATCHMAN_CONFIG_DIR=str(root),
                   PATH=str(JQ) + ':' + os.environ['PATH'])
        return subprocess.run(['bash', str(script)], input=input_text, text=True,
                              capture_output=True, env=env, timeout=10)

    def test_model_saved_and_reloaded(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            r = self.run_wizard(root, 'qwen3.5:7b\ny\n')
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('MODEL:qwen3.5:7b', r.stdout)
            self.assertEqual(json.loads((root / 'watchman.json').read_text())['ollama_model'], 'qwen3.5:7b')

    def test_injection_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            r = self.run_wizard(root, 'model;echo unsafe\ny\n')
            self.assertNotEqual(r.returncode, 0)
            self.assertFalse((root / 'watchman.json').exists())


if __name__ == '__main__':
    unittest.main()
