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
 # Legacy bare-header layout (no type= field); kept to cover the fallback path.
 def setup_mock_hardware(self):
  (self.p/'disks.ini').write_text('[disk1]\nname="disk1"\ndevice="sdc"\n[disk2]\nname="disk2"\ndevice="sdd"\n')
  b=self.p/'bin';b.mkdir()
  docker=b/'docker'
  docker.write_text('#!/bin/sh\nprintf "alpha\nbeta\n"\n')
  docker.chmod(0o755)
  self.env['PATH']=str(b)+':'+self.env['PATH']
  (self.p/'unraid-autostart').write_text('alpha\nbeta 10\n')   # Unraid format: name [delay]
  self.env['WATCHMAN_DOCKER_AUTOSTART']=str(self.p/'unraid-autostart')
 def tty(self,answers):
  import shlex
  cmd='bash '+shlex.quote(str(self.p/'watchman.sh'))
  return subprocess.run(['script','-q','-e','-c',cmd,'/dev/null'],input=answers,env=self.env,capture_output=True,text=True,timeout=5)
 def test_discovery_save_and_engine_load(self):
  self.setup_mock_hardware()
  r=self.tty('1\n\ny\n0\n')
  self.assertEqual(r.returncode,0,r.stderr+r.stdout)
  c=json.loads((self.p/'config/watchman.json').read_text())
  self.assertEqual(c['disks'],['disk1','disk2'])
  self.assertEqual(c['containers'],['alpha','beta'])
  x=self.run_cmd('--report')
  self.assertIn('DISKS=["disk1","disk2"]',x.stdout)
 def test_discovery_cancel_does_not_save(self):
  self.setup_mock_hardware()
  r=self.tty('1\n\nn\n0\n')
  self.assertEqual(r.returncode,0,r.stderr)
  self.assertFalse((self.p/'config/watchman.json').exists())
 def test_existing_settings_preserved_and_backup(self):
  self.setup_mock_hardware()
  (self.p/'config').mkdir()
  old=dict(version='0.4.2',disks=['disk9'],containers=['old'],gpu_warn=72,ram_warn=83,disk_temp_default=48)
  (self.p/'config/watchman.json').write_text(json.dumps(old))
  r=self.tty('1\n\ny\n0\n')
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
  r=self.tty('1\n\ny\n0\n')
  self.assertNotEqual(r.returncode,0)
  self.assertEqual(config.read_text(),'not-json')
 def test_restore_backup_confirmed(self):
  self.setup_mock_hardware()
  (self.p/'config').mkdir()
  old=dict(version='0.4.2',disks=['disk9'],containers=['old'])
  (self.p/'config/watchman.json').write_text(json.dumps(old))
  self.assertEqual(self.tty('1\n\ny\n0\n').returncode,0)
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
  r=self.tty('1\n\ny\n0\n')
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
  r=self.tty('1\n\ny\n0\n')
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
 # Unraid-style quoted headers with parity, flash, empty slot, two named pools and a 2-device pool.
 UNRAID_INI=('["parity"]\nname="parity"\ntype="Parity"\ndevice="sdb"\nid="WDC_WD20EFRX-68EUZN0_WD-PARITY0001"\n'
  '["parity2"]\nname="parity2"\ntype="Parity"\ndevice=""\nid=""\n'
  '["disk1"]\nname="disk1"\ntype="Data"\ndevice="sdc"\nid="WDC_WD20EFRX-68EUZN0_WD-DATA0001"\n'
  '["disk2"]\nname="disk2"\ntype="Data"\ndevice="sdd"\nid="WDC_WD20EFRX-68EUZN0_WD-DATA0002"\n'
  '["disk3"]\nname="disk3"\ntype="Data"\ndevice=""\nid=""\n'
  '["Media-pool"]\nname="Media-pool"\ntype="Cache"\ndevice="sde"\nid="ST2000DM008_ZFL0001"\n'
  '["Mediapool"]\nname="Mediapool"\ntype="Cache"\ndevice="nvme0n1"\nid="Samsung_SSD_970_EVO_Plus_1TB_S4EW0001"\n'
  '["Mediapool2"]\nname="Mediapool2"\ntype="Cache"\ndevice="nvme1n1"\nid="Samsung_SSD_970_EVO_Plus_1TB_S4EW0002"\n'
  '["flash"]\nname="flash"\ntype="Flash"\ndevice="sda"\nid="SanDisk_Cruzer_Fit_4C530001"\n')
 def test_discovery_unraid_quoted_layout(self):
  self.setup_mock_hardware()
  (self.p/'disks.ini').write_text(self.UNRAID_INI)
  r=self.tty('1\n\ny\n0\n')
  self.assertEqual(r.returncode,0,r.stderr+r.stdout)
  c=json.loads((self.p/'config/watchman.json').read_text())
  self.assertEqual(c['disks'],['Media-pool','Mediapool','Mediapool2','disk1','disk2'])
  for line in ('parity: parity (always reported by engine)','parity2: parity','disk3: empty slot','flash: boot flash'):
   self.assertIn(line,r.stdout)
 # Section names/types as read from JohnsVault (Unraid 7.3.2) on 2026-11-14; serials are fake.
 def test_discovery_johnsvault_layout(self):
  self.setup_mock_hardware()
  s=lambda n,t,d,i:f'["{n}"]\ndevice="{d}"\nid="{i}"\nstatus="DISK_OK"\ntype="{t}"\n'
  (self.p/'disks.ini').write_text(s('parity','Parity','sdh','ST1000DM010_FAKE0001')+s('disk1','Data','sdg','WDC_WD10EZEX_FAKE0002')
   +s('disk2','Data','','')+s('parity2','Parity','','')+s('cache','Cache','sdd','SKhynix_FAKE0003')
   +s('media-pool','Cache','sdc','WDC_WD2004FBYZ_FAKE0004')+s('mediapool','Cache','sdb','WDC_WD2004FBYZ_FAKE0005')
   +s('storage','Cache','nvme0n1','Samsung_990_FAKE0006')+s('flash','Flash','sda','USB_FAKE0007-0:0'))
  r=self.tty('1\n\ny\n0\n')
  self.assertEqual(r.returncode,0,r.stderr+r.stdout)
  self.assertEqual(json.loads((self.p/'config/watchman.json').read_text())['disks'],['cache','disk1','media-pool','mediapool','storage'])
 def test_discovery_crlf_and_unknown_type(self):
  self.setup_mock_hardware()
  (self.p/'disks.ini').write_text('["disk1"]\r\nname="disk1"\r\ntype="Data"\r\ndevice="sdc"\r\n["odd"]\r\ntype="Mystery"\r\ndevice="sdz"\r\n')
  r=self.tty('1\n\ny\n0\n')
  self.assertEqual(r.returncode,0,r.stderr+r.stdout)
  self.assertEqual(json.loads((self.p/'config/watchman.json').read_text())['disks'],['disk1'])
  self.assertIn('odd: unrecognized type Mystery',r.stdout)
 def test_empty_discovery_never_wipes_existing_disks(self):
  self.setup_mock_hardware()
  (self.p/'disks.ini').write_text('["parity"]\ntype="Parity"\ndevice="sdb"\n["flash"]\ntype="Flash"\ndevice="sda"\n')
  (self.p/'config').mkdir()
  old=dict(version='0.4.2',disks=['disk1','Media-pool'],containers=['old'])
  (self.p/'config/watchman.json').write_text(json.dumps(old))
  r=self.tty('1\n\ny\n0\n')
  self.assertEqual(r.returncode,0,r.stderr+r.stdout)
  self.assertIn('Nothing saved; existing selections kept',r.stdout)
  self.assertEqual(json.loads((self.p/'config/watchman.json').read_text()),old)
  self.assertFalse((self.p/'config/watchman.json.bak').exists())
 # ---- container picker ----
 def picker(self, answers, autostart='beta\n'):
  self.setup_mock_hardware()
  (self.p/'bin/docker').write_text('#!/bin/sh\nprintf "gamma\\trunning\\nalpha\\trunning\\nbeta\\texited\\n"\n')
  if autostart is None: (self.p/'unraid-autostart').unlink()
  else: (self.p/'unraid-autostart').write_text(autostart)
  r=self.tty('1\n'+answers+'0\n')
  cfg=self.p/'config/watchman.json'
  return r, (json.loads(cfg.read_text())['containers'] if cfg.exists() else None)
 def test_picker_defaults_to_unraid_autostart(self):
  r,c=self.picker('\ny\n')
  self.assertEqual(c,['beta'])
  self.assertRegex(r.stdout,r'2 \[x\] beta +exited, autostart')
  self.assertRegex(r.stdout,r'1 \[ \] alpha +running')
 def test_picker_toggle_select_and_deselect(self):
  r,c=self.picker('1 2\n\ny\n')        # alpha on, beta off
  self.assertEqual(c,['alpha'])
 def test_picker_all_none_defaults_and_bad_input(self):
  self.assertEqual(self.picker('a\n\ny\n')[1],['alpha','beta','gamma'])
  self.tearDown(); self.setUp()
  self.assertEqual(self.picker('a n\n\ny\n')[1],[])
  self.tearDown(); self.setUp()
  r,c=self.picker('n d 9 x\n\ny\n')
  self.assertEqual(c,['beta']); self.assertIn('Ignored: 9',r.stdout); self.assertIn('Ignored: x',r.stdout)
 def test_picker_without_unraid_autostart_list(self):
  r,c=self.picker('\ny\n',autostart=None)   # JohnsVault today: no autostart file
  self.assertEqual(c,[])
  self.assertIn('Unraid has no containers set to autostart',r.stdout)
 def test_picker_cancel_saves_nothing(self):
  r,c=self.picker('2\nq\n')
  self.assertIsNone(c)
  self.assertIn('Canceled; nothing saved.',r.stdout)
 def test_invalid_config_fails_closed(self):
  (self.p/'config').mkdir()
  (self.p/'config/watchman.json').write_text('{"version":"0.4.2","disks":"bad","containers":[]}')
  r=self.run_cmd('--report');self.assertNotEqual(r.returncode,0);self.assertIn('Invalid configuration',r.stderr)
if __name__=='__main__': unittest.main()
