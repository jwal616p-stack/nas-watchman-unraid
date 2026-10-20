"""Alert state continuity across incomplete telemetry, using engine jq expressions."""
import json
import subprocess
import unittest
from pathlib import Path

ENGINE = (Path(__file__).parent / 'watchman_engine.sh').read_text()
JQ = str(Path(__file__).parent.parent / 'nas-watchman-release-candidate/.test-tools/bin/jq')


def jq_run(expression, *inputs):
    p = subprocess.run([JQ, '-n', '--argjson', 'old', json.dumps(inputs[0]),
                        '--argjson', 'now', json.dumps(inputs[1]), expression],
                       capture_output=True, text=True, check=True)
    return json.loads(p.stdout)


class AlertHistory(unittest.TestCase):
    def test_missing_sensor_does_not_clear_previous_alert(self):
        previous = {'ram': {'bad': True, 'message': 'RAM high'},
                    'gpu': {'bad': True, 'message': 'GPU hot'},
                    'telemetry': {'bad': False, 'message': 'reachable'}}
        outage = {'telemetry': {'bad': True, 'message': 'unavailable'}}
        merged = jq_run('$old * $now', previous, outage)
        self.assertTrue(merged['ram']['bad'])
        self.assertTrue(merged['gpu']['bad'])
        self.assertTrue(merged['telemetry']['bad'])

    def test_recovered_telemetry_does_not_fake_sensor_recovery(self):
        previous = {'ram': {'bad': True, 'message': 'RAM high'},
                    'telemetry': {'bad': True, 'message': 'unavailable'}}
        partial = {'telemetry': {'bad': False, 'message': 'reachable'}}
        merged = jq_run('$old * $now', previous, partial)
        self.assertTrue(merged['ram']['bad'])
        self.assertFalse(merged['telemetry']['bad'])

    def test_real_recovery_only_after_valid_sensor_reading(self):
        previous = {'ram': {'bad': True, 'message': 'RAM high'}}
        observed = {'ram': {'bad': False, 'message': 'RAM normal'}}
        merged = jq_run('$old * $now', previous, observed)
        self.assertFalse(merged['ram']['bad'])

    def test_engine_contains_state_merge(self):
        self.assertIn("jq -s '.[0] * .[1]'", ENGINE)

    def test_engine_only_compares_observed_keys(self):
        self.assertIn('$now[0] | to_entries', ENGINE)


if __name__ == '__main__':
    unittest.main()
