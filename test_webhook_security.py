import os,subprocess,tempfile,unittest
from pathlib import Path
P=Path(__file__).parent
class WebhookSecurity(unittest.TestCase):
 def check(self,code='204',url='https://discord.com/api/webhooks/123456/FAKE_TEST_TOKEN'):
  with tempfile.TemporaryDirectory() as d:
   p=Path(d); (p/'bin').mkdir()
   f=p/'bin/curl'
   f.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$ARGS"\ncat > "$STDIN"\nprintf "%s" "$STATUS"\n');f.chmod(0o700)
   (p/'secret').write_text(url+'\n')
   source=(P/'watchman_engine.sh').read_text().split('\ncollect || exit 1\n')[0]
   (p/'run.sh').write_text(source+'\nsend_chunk "test message"\n')
   env=dict(os.environ,WATCHMAN_STATE_DIR=str(p/'state'),WATCHMAN_WEBHOOK_FILE=str(p/'secret'),ARGS=str(p/'args'),STDIN=str(p/'stdin'),STATUS=code,PATH=str(p/'bin')+':'+str(P.parent/'nas-watchman-release-candidate/.test-tools/bin')+':'+os.environ['PATH'])
   r=subprocess.run(['bash',str(p/'run.sh')],env=env,capture_output=True,text=True,timeout=10)
   return r,(p/'args').read_text() if (p/'args').exists() else '',(p/'stdin').read_text() if (p/'stdin').exists() else ''
 def test_secret_not_in_args_or_logs(self):
  r,a,i=self.check();self.assertEqual(r.returncode,0,r.stderr);self.assertIn('FAKE_TEST_TOKEN',i);self.assertNotIn('FAKE_TEST_TOKEN',a+r.stdout+r.stderr)
 def test_http_failure_redacts(self):
  r,a,i=self.check('403');self.assertNotEqual(r.returncode,0);self.assertIn('HTTP 403',r.stderr);self.assertNotIn('FAKE_TEST_TOKEN',a+r.stdout+r.stderr)
 def test_invalid_url_rejected_without_curl(self):
  r,a,i=self.check(url='https://invalid.example/SECRET');self.assertNotEqual(r.returncode,0);self.assertIn('Invalid webhook URL',r.stderr);self.assertEqual(a,'')
