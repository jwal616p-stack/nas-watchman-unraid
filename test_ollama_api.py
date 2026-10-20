"""Offline Ollama contract tests; all HTTP calls intercepted."""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).parent
JQ = HERE.parent / 'nas-watchman-release-candidate/.test-tools/bin'


class OllamaApi(unittest.TestCase):
    def simulate(self, response='success'):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            fake_bin = root / 'bin'
            fake_bin.mkdir()
            curl = fake_bin / 'curl'
            curl.write_text('''#!/bin/sh
case "$*" in
 *"/api/generate"*)
  for arg do
    case "$arg" in
     @*) cp "${arg#@}" "$WATCHMAN_TEST_CAPTURE" ;;
    esac
  done
  if [ "$WATCHMAN_TEST_RESPONSE" = failure ]; then exit 7; fi
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then shift; printf '%s\\n' '{"done":true,"response":"Measured RAM is 40 percent."}' > "$1"; exit 0; fi
    shift
  done
  ;;
esac
exit 8
''')
            curl.chmod(0o700)
            engine = (HERE / 'watchman_engine.sh').read_text()
            prelude = engine.split('\ncollect || exit 1\n')[0]
            script = root / 'probe.sh'
            script.write_text(prelude + '\nprintf "RAM: 40%%\\n" > "$WORK/report"\nai\n')
            capture = root / 'request.json'
            env = dict(os.environ, WATCHMAN_STATE_DIR=str(root / 'state'),
                       WATCHMAN_OLLAMA_MODEL='qwen3.5:7b',
                       WATCHMAN_TEST_CAPTURE=str(capture),
                       WATCHMAN_TEST_RESPONSE=response,
                       PATH=str(fake_bin) + ':' + str(JQ) + ':' + os.environ['PATH'])
            result = subprocess.run(['bash', str(script)], env=env, text=True,
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout, json.loads(capture.read_text())

    def test_selected_model_and_report_sent(self):
        output, request = self.simulate()
        self.assertEqual(request['model'], 'qwen3.5:7b')
        self.assertIn('RAM: 40%', request['prompt'])
        self.assertFalse(request['stream'])
        self.assertIn('Measured RAM is 40 percent.', output)

    def test_ollama_failure_keeps_report_valid(self):
        output, request = self.simulate('failure')
        self.assertIn('AI unavailable; measured readings remain valid.', output)
        self.assertEqual(request['model'], 'qwen3.5:7b')


if __name__ == '__main__':
    unittest.main()
