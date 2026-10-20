import json,os,subprocess,tempfile,unittest
from pathlib import Path
SRC=Path(__file__).parent
JQ=SRC.parent/'nas-watchman-release-candidate/.test-tools/bin'
class LauncherTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
  self.p=Path(self.temp.name)
  (self.p/'watchman.sh').write_bytes((SRC/'watchman.sh').read_bytes())
  (self.p/'watchman_engine.sh').write_text('#!/bin/bash\nprintf "MODE=%s DISKS=%s CONTAINERS=%s GPU=%s\\n" "$1" "${WATCHMAN_DISKS:-}" "${WATCHMAN_CONTAINERS:-}" "${GPU_WARN:-}"\n')
  self.env=dict(os.environ,PATH=str(JQ)+':'+os.environ['PATH'],WATCHMAN_CONFIG_DIR=str(self.p/'config'),WATCHMAN_DISKS_INI=str(self.p/'disks.ini'))
 def run_cmd(self,*args):
  return subprocess.run(['bash',str(self.p/'watchman.sh'),*args],env=self.env,input='',text=True,capture_output=True,timeout=5)
 def test_help(self):
  r=self.run_cmd('--help');self.assertEqual(r.returncode,0,r.stderr);self.assertIn('Usage:',r.stdout)
 def test_report(self):
  r=self.run_cmd('--report');self.assertEqual(r.returncode,0,r.stderr);self.assertIn('MODE=--report',r.stdout)
 def test_no_tty_report(self):
  r=self.run_cmd();self.assertEqual(r.returncode,0,r.stderr);self.assertIn('MODE=--report',r.stdout)
 def test_unknown_flag(self):
  self.assertEqual(self.run_cmd('--bogus').returncode,2)
 def test_valid_config(self):
  (self.p/'config').mkdir()
  (self.p/'config/watchman.json').write_text(json.dumps(dict(version='0.4.2',disks=['disk2'],containers=['alpha'],gpu_warn=70)))
  r=self.run_cmd('--once');self.assertEqual(r.returncode,0,r.stderr);self.assertIn('DISKS=["disk2"]',r.stdout);self.assertIn('CONTAINERS=["alpha"]',r.stdout);self.assertIn('GPU=70',r.stdout)
 def test_tty_menu_exit(self):
  import shlex
  cmd='bash '+shlex.quote(str(self.p/'watchman.sh'))
  r=subprocess.run(['script','-q','-e','-c',cmd,'/dev/null'],input='0\n',env=self.env,capture_output=True,text=True,timeout=5)
  self.assertEqual(r.returncode,0,r.stderr)
  self.assertIn('Chief Security Officer',r.stdout)
  self.assertIn('Choice:',r.stdout)
 def test_tty_help_bypasses_menu(self):
  import shlex
  cmd='bash '+shlex.quote(str(self.p/'watchman.sh'))+' --help'
  r=subprocess.run(['script','-q','-e','-c',cmd,'/dev/null'],input='',env=self.env,capture_output=True,text=True,timeout=5)
  self.assertEqual(r.returncode,0,r.stderr)
  self.assertNotIn('Chief Security Officer',r.stdout)
 def test_missing_discovery_does_not_save(self):
  import shlex
  cmd='bash '+shlex.quote(str(self.p/'watchman.sh'))
  r=subprocess.run(['script','-q','-e','-c',cmd,'/dev/null'],input='1\ny\n0\n',env=self.env,capture_output=True,text=True,timeout=5)
  self.assertEqual(r.returncode,0,r.stderr)
  self.assertIn('Discovery incomplete',r.stdout)
  self.assertFalse((self.p/'config/watchman.json').exists())
 def setup_mock_hardware(self):
  (self.p/'disks.ini').write_text('[disk1]\nname="disk1"\n[disk2]\nname="disk2"\n')
  b=self.p/'bin';b.mkdir()
  docker=b/'docker'
  docker.write_text('#!/bin/sh\nprintf "alpha\nbeta\n"\n')
  docker.chmod(0o755)
  self.env['PATH']=str(b)+':'+self.env['PATH']
 def tty(self,answers):
  import shlex
  cmd='bash '+shlex.quote(str(self.p/'watchman.sh'))
  return subprocess.run(['script','-q','-e','-c',cmd,'/dev/null'],input=answers,env=self.env,capture_output=True,text=True,timeout=5)
 def test_discovery_save_and_engine_load(self):
  self.setup_mock_hardware()
  r=self.tty('1\ny\n0\n')
  self.assertEqual(r.returncode,0,r.stderr+r.stdout)
  c=json.loads((self.p/'config/watchman.json').read_text())
  self.assertEqual(c['disks'],['disk1','disk2'])
  self.assertEqual(c['containers'],['alpha','beta'])
  x=self.run_cmd('--report')
  self.assertIn('DISKS=["disk1","disk2"]',x.stdout)
 def test_discovery_cancel_does_not_save(self):
  self.setup_mock_hardware()
  r=self.tty('1\nn\n0\n')
  self.assertEqual(r.returncode,0,r.stderr)
  self.assertFalse((self.p/'config/watchman.json').exists())
 def test_existing_settings_preserved_and_backup(self):
  self.setup_mock_hardware()
  (self.p/'config').mkdir()
  old=dict(version='0.4.2',disks=['disk9'],containers=['old'],gpu_warn=72,ram_warn=83,disk_temp_default=48)
  (self.p/'config/watchman.json').write_text(json.dumps(old))
  r=self.tty('1\ny\n0\n')
  self.assertEqual(r.returncode,0,r.stderr+r.stdout)
  new=json.loads((self.p/'config/watchman.json').read_text())
  self.assertEqual(new['gpu_warn'],72)
  self.assertEqual(new['ram_warn'],83)
  self.assertEqual(new['disk_temp_default'],48)
  self.assertEqual(json.loads((self.p/'config/watchman.json.bak').read_text()),old)
  self.assertEqual(new['disks'],['disk1','disk2'])
 def test_invalid_existing_config_not_overwritten(self):
  self.setup_mock_hardware()
  (self.p/'config').mkdir()
  config=self.p/'config/watchman.json'
  config.write_text('not-json')
  r=self.tty('1\ny\n0\n')
  self.assertNotEqual(r.returncode,0)
  self.assertEqual(config.read_text(),'not-json')
 def test_restore_backup_confirmed(self):
  self.setup_mock_hardware()
  (self.p/'config').mkdir()
  old=dict(version='0.4.2',disks=['disk9'],containers=['old'])
  (self.p/'config/watchman.json').write_text(json.dumps(old))
  self.assertEqual(self.tty('1\ny\n0\n').returncode,0)
  r=self.tty('4\ny\n0\n')
  self.assertEqual(r.returncode,0,r.stderr+r.stdout)
  self.assertEqual(json.loads((self.p/'config/watchman.json').read_text()),old)
 def test_restore_backup_cancelled(self):
  (self.p/'config').mkdir()
  current=dict(version='0.4.2',disks=['disk1'],containers=[])
  previous=dict(version='0.4.2',disks=['disk2'],containers=[])
  (self.p/'config/watchman.json').write_text(json.dumps(current))
  (self.p/'config/watchman.json.bak').write_text(json.dumps(previous))
  self.assertEqual(self.tty('4\nn\n0\n').returncode,0)
  self.assertEqual(json.loads((self.p/'config/watchman.json').read_text()),current)
 def test_corrupt_backup_refused(self):
  (self.p/'config').mkdir()
  current=dict(version='0.4.2',disks=['disk1'],containers=[])
  (self.p/'config/watchman.json').write_text(json.dumps(current))
  (self.p/'config/watchman.json.bak').write_text('invalid')
  r=self.tty('4\ny\n0\n')
  self.assertNotEqual(r.returncode,0)
  self.assertEqual(json.loads((self.p/'config/watchman.json').read_text()),current)
 def test_failed_commit_preserves_old_config_and_backup(self):
  self.setup_mock_hardware()
  (self.p/'config').mkdir()
  old=dict(version='0.4.2',disks=['disk9'],containers=['old'],gpu_warn=75)
  (self.p/'config/watchman.json').write_text(json.dumps(old))
  b=self.p/'bin/mv'
  b.write_text('#!/bin/sh\ncase "$*" in *".watchman."*) exit 44;; esac\nexec /usr/bin/mv "$@"\n')
  b.chmod(0o755)
  r=self.tty('1\ny\n0\n')
  self.assertNotEqual(r.returncode,0,r.stdout)
  self.assertEqual(json.loads((self.p/'config/watchman.json').read_text()),old)
  self.assertEqual(json.loads((self.p/'config/watchman.json.bak').read_text()),old)
  self.assertFalse(list((self.p/'config').glob('.watchman.*')))
 def test_failed_backup_copy_preserves_old_config(self):
  self.setup_mock_hardware()
  (self.p/'config').mkdir()
  old=dict(version='0.4.2',disks=['disk9'],containers=['old'])
  (self.p/'config/watchman.json').write_text(json.dumps(old))
  b=self.p/'bin/cp'
  b.write_text('#!/bin/sh\nexit 44\n')
  b.chmod(0o755)
  r=self.tty('1\ny\n0\n')
  self.assertNotEqual(r.returncode,0,r.stdout)
  self.assertEqual(json.loads((self.p/'config/watchman.json').read_text()),old)
  self.assertFalse(list((self.p/'config').glob('.watchman*')))
 def test_corrupt_primary_valid_backup_guidance(self):
  (self.p/"config").mkdir()
  (self.p/"config/watchman.json").write_text("corrupt")
  old=dict(version="0.4.2",disks=["disk1"],containers=[])
  (self.p/"config/watchman.json.bak").write_text(json.dumps(old))
  r=self.run_cmd("--report")
  self.assertNotEqual(r.returncode,0)
  self.assertIn("Valid backup available",r.stderr)
  self.assertEqual((self.p/"config/watchman.json").read_text(),"corrupt")
 def test_corrupt_primary_no_valid_backup_guidance(self):
  (self.p/"config").mkdir()
  (self.p/"config/watchman.json").write_text("corrupt")
  (self.p/"config/watchman.json.bak").write_text("also corrupt")
  r=self.run_cmd("--report")
  self.assertNotEqual(r.returncode,0)
  self.assertIn("manual recovery required",r.stderr)
 def test_invalid_config_fails_closed(self):
  (self.p/'config').mkdir()
  (self.p/'config/watchman.json').write_text('{"version":"0.4.2","disks":"bad","containers":[]}')
  r=self.run_cmd('--report');self.assertNotEqual(r.returncode,0);self.assertIn('Invalid configuration',r.stderr)
if __name__=='__main__': unittest.main()
