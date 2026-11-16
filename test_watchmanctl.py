"""Installer / boot / supervisor lifecycle tests against a fake Unraid root (WATCHMAN_ROOT).

Never touches the real /boot, /usr/local, /var/run or /mnt. A fake legacy v0.3 install is checked
byte-for-byte after every test, as are the original lines of the fake /boot/config/go.
"""
import hashlib
import json
import os
import shutil
import stat
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC_FILES = ('watchman.sh', 'watchman_engine.sh', 'watchman_local_metrics.sh', 'watchman_smart.sh', 'watchmanctl.sh', 'VERSION', 'install.sh')
GO_ORIGINAL = '#!/bin/bash\n# Let Unraid manage ZFS pools.\nsysctl -w vm.dirty_ratio=5\n'


def digest(path):
    h = hashlib.sha256()
    for p in sorted(Path(path).rglob('*')):
        h.update(str(p.relative_to(path)).encode())
        if p.is_file():
            h.update(p.read_bytes())
    return h.hexdigest()


class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp(prefix='wm-ctl-'))
        self.root = self.t / 'root'
        self.src = self.t / 'src'
        self.src.mkdir()
        for f in SRC_FILES:
            shutil.copy(HERE / f, self.src / f)
        r = self.root
        (r / 'boot/config/plugins/nas-watchman').mkdir(parents=True)
        (r / 'boot/config/go').write_text(GO_ORIGINAL)
        (r / 'boot/config/plugins/nas-watchman/watchman.sh').write_text('# legacy v0.3\n')
        (r / 'boot/config/plugins/nas-watchman/discord-webhook').write_text('https://discord.com/api/webhooks/1/legacy\n')
        (r / 'var/local/emhttp').mkdir(parents=True)
        (r / 'var/local/emhttp/var.ini').write_text('mdState="STOPPED"\n')
        (r / 'var/local/emhttp/disks.ini').write_text('["disk1"]\nname="disk1"\ntype="Data"\ndevice="sdc"\nid="WDC_X_0001"\n')
        (r / 'mnt/user').mkdir(parents=True)
        for d in ('usr/local/emhttp/plugins', 'usr/local/bin', 'var/run', 'var/log'):
            (r / d).mkdir(parents=True)
        self.legacy = digest(r / 'boot/config/plugins/nas-watchman')
        self.stubs = self.t / 'stubs'
        self.stubs.mkdir()
        for name, body in (('nvidia-smi', 'echo "0, 41, 0, 33, 12288, GPU-a, 00000000:03:00.0, RTX"'),
                           ('docker', 'printf "ollama\\trunning\\n"'),
                           # Never call Discord from an isolated lifecycle test; 200 means delivered.
                           ('curl', 'printf "200"')):
            (self.stubs / name).write_text('#!/bin/sh\n' + body + '\n')
            (self.stubs / name).chmod(0o755)
        self.env = dict(os.environ, WATCHMAN_ROOT=str(r), WATCHMAN_POLL='0.2',
                        PATH=str(self.stubs) + ':' + os.environ['PATH'])
        self.flash = r / 'boot/config/plugins/watchman'
        self.rt = r / 'usr/local/emhttp/plugins/watchman'
        self.bin = r / 'usr/local/bin/watchman'
        self.run_dir = r / 'var/run/watchman'
        self.state = r / 'mnt/user/appdata/watchman'

    def tearDown(self):
        if self.bin.exists():
            subprocess.run(['bash', str(self.bin), 'stop'], env=self.env, capture_output=True, timeout=30)
        subprocess.run(['pkill', '-f', str(self.root)], capture_output=True)
        time.sleep(0.2)
        try:
            self.assertEqual(digest(self.root / 'boot/config/plugins/nas-watchman'), self.legacy, 'legacy v0.3 changed')
            go = (self.root / 'boot/config/go').read_text()
            self.assertTrue(go.startswith(GO_ORIGINAL), 'original go lines changed')
        finally:
            shutil.rmtree(self.t, ignore_errors=True)

    # ---- helpers ----
    def install(self, src=None, **kw):
        return subprocess.run(['bash', str((src or self.src) / 'install.sh')], env=self.env, text=True,
                              capture_output=True, timeout=60, **kw)

    def wm(self, *args, timeout=60):
        return subprocess.run(['bash', str(self.bin), *args], env=self.env, text=True, capture_output=True, timeout=timeout)

    def ptr(self, name):
        p = self.flash / name
        return p.read_text().strip() if p.exists() else None

    def status_text(self):
        p = self.run_dir / 'status'
        return p.read_text().strip() if p.exists() else ''

    def wait(self, pred, what, timeout=15):
        end = time.time() + timeout
        while time.time() < end:
            if pred():
                return
            time.sleep(0.1)
        self.fail('timed out waiting for ' + what + '; status=' + self.status_text() +
                  '\nlog:\n' + ((self.root / 'var/log/watchman.log').read_text()[-2000:] if (self.root / 'var/log/watchman.log').exists() else ''))

    def array_up(self):
        (self.root / 'var/local/emhttp/var.ini').write_text('mdState="STARTED"\n')
        (self.root / 'mnt/user/appdata').mkdir(exist_ok=True)
        (self.root / '.test-mounted').touch()

    def array_down(self):
        (self.root / '.test-mounted').unlink(missing_ok=True)
        (self.root / 'var/local/emhttp/var.ini').write_text('mdState="STOPPED"\n')

    def engine_running(self):
        return (self.run_dir / 'engine.pid').exists()

    def supervisors(self):
        out = subprocess.run(['pgrep', '-f', str(self.rt / 'watchmanctl.sh') + ' run'], capture_output=True, text=True).stdout
        return [p for p in out.split() if p]

    def bump(self, version):
        (self.src / 'VERSION').write_text(version + '\n')

    def seed_config_and_history(self):
        cfg = self.flash / 'config'
        (cfg / 'watchman.json').write_text('{"version":"0.4.2","disks":["disk1"],"containers":["ollama"],"gpu_warn":80}\n')
        (cfg / 'discord-webhook').write_text('https://discord.com/api/webhooks/123/abcDEF\n')
        self.state.mkdir(parents=True, exist_ok=True)
        (self.state / 'state.json').write_text('{"upgrade_sentinel":{"bad":true,"message":"kept"}}\n')
        return digest(cfg), (self.state / 'state.json').read_bytes()

    # ---- tests ----
    def test_fresh_install_waits_without_creating_state(self):
        r = self.install()
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertIn('watchman setup', r.stdout)
        cur = self.ptr('current')
        self.assertTrue(cur.startswith('0.4.5-dev-'))
        self.assertTrue((self.flash / 'releases' / cur / 'watchman_engine.sh').exists())
        go = (self.root / 'boot/config/go').read_text()
        self.assertEqual(go.count('NAS Watchman autostart'), 1)
        self.assertEqual((self.root / 'boot/config/go.watchman-backup').read_text(), GO_ORIGINAL)
        for ev in ('disks_mounted', 'started', 'stopping'):
            self.assertTrue(os.access(self.rt / 'event' / ev, os.X_OK), ev)
        self.wait(lambda: 'waiting' in self.status_text(), 'waiting status')
        (self.root / 'mnt/user/appdata').mkdir()   # appdata visible but array still stopped
        time.sleep(1)
        self.assertFalse(self.state.exists(), 'state created before array started')
        self.assertFalse(self.engine_running())
        self.assertIn('not ready', self.wm('status').stdout)

    def test_starts_on_array_and_pauses_for_stopping_event(self):
        self.install()
        self.array_up()
        self.wait(self.engine_running, 'engine start')
        self.wait(lambda: self.status_text() == 'running', 'running status')
        self.assertTrue(self.state.is_dir())
        ev = subprocess.run(['bash', str(self.rt / 'event' / 'stopping')], env=self.env, timeout=30)
        self.assertEqual(ev.returncode, 0)
        self.assertFalse(self.engine_running(), 'stopping event returned before engine stopped')
        self.assertEqual(len(self.supervisors()), 1)
        self.array_down()
        self.wait(lambda: 'waiting' in self.status_text(), 'waiting after array stop')
        self.array_up()
        self.wait(self.engine_running, 'engine restart after array start')

    def test_single_instance(self):
        self.install()
        self.wait(lambda: len(self.supervisors()) == 1, 'one supervisor')
        self.assertIn('already running', self.wm('start').stdout)
        subprocess.run(['bash', str(self.rt / 'watchmanctl.sh'), 'run'], env=self.env, timeout=10)  # exits at once
        for ev in ('disks_mounted', 'started'):
            subprocess.run(['bash', str(self.rt / 'event' / ev)], env=self.env, timeout=10)
        time.sleep(1)
        self.assertEqual(len(self.supervisors()), 1)

    def test_stop_start_status(self):
        self.install()
        self.array_up()
        self.wait(self.engine_running, 'engine')
        s = self.wm('stop')
        self.assertIn('stopped', s.stdout)
        self.assertEqual(self.supervisors(), [])
        st = self.wm('status')
        self.assertEqual(st.returncode, 3)
        self.assertIn('not running', st.stdout)
        self.assertIn('Watchman started', self.wm('start').stdout)
        self.wait(self.engine_running, 'engine after start')
        self.assertEqual(self.wm('status').returncode, 0)

    def test_upgrade_preserves_config_and_history(self):
        self.install()
        self.array_up()
        self.wait(self.engine_running, 'engine')
        old = self.ptr('current')
        cfg, hist = self.seed_config_and_history()
        self.bump('0.4.5-dev')
        r = self.install()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(self.ptr('current').startswith('0.4.5-dev-'))
        self.assertEqual(self.ptr('previous'), old)
        self.assertEqual(digest(self.flash / 'config'), cfg)
        self.assertEqual(json.loads((self.state / 'state.json').read_text())['upgrade_sentinel'], json.loads(hist)['upgrade_sentinel'])
        self.assertEqual((self.root / 'boot/config/go').read_text().count('NAS Watchman autostart'), 1)
        self.wait(self.engine_running, 'engine after upgrade')
        self.assertNotIn('differs', self.wm('status').stdout)
        self.assertEqual((self.rt / 'RELEASE').read_text().strip(), self.ptr('current'))

    def assert_unchanged_after_failed_upgrade(self, before, r):
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.ptr('current'), before)
        self.assertEqual((self.rt / 'RELEASE').read_text().strip(), before)
        self.assertEqual([p.name for p in (self.flash / 'releases').iterdir() if p.name.startswith('.')], [])
        self.wait(self.engine_running, 'old engine still running')

    def test_failed_upgrade_syntax_error_changes_nothing(self):
        self.install()
        self.array_up()
        self.wait(self.engine_running, 'engine')
        before = self.ptr('current')
        self.bump('0.4.5-dev')
        with open(self.src / 'watchman_engine.sh', 'a') as f:
            f.write('\nif then fi\n')
        r = self.install()
        self.assertIn('syntax error', r.stderr)
        self.assert_unchanged_after_failed_upgrade(before, r)

    def test_failed_upgrade_selftest_changes_nothing(self):
        self.install()
        self.array_up()
        self.wait(self.engine_running, 'engine')
        before = self.ptr('current')
        self.bump('0.4.5-dev')
        (self.src / 'watchman_local_metrics.sh').write_text('#!/bin/bash\necho broken\n')
        r = self.install()
        self.assertIn('self-test failed', r.stderr)
        self.assert_unchanged_after_failed_upgrade(before, r)

    def interrupt_upgrade(self, sig):
        self.install()
        self.array_up()
        self.wait(self.engine_running, 'engine')
        before = self.ptr('current')
        self.bump('0.4.5-dev')
        marker = self.t / 'midway'
        slow = self.t / 'slowbin'
        slow.mkdir()
        (slow / 'cp').write_text('#!/bin/sh\ncase "$*" in *.staging.*watchman_engine.sh*) touch "%s"; sleep 1;; esac\nexec /usr/bin/cp "$@"\n' % marker)
        (slow / 'cp').chmod(0o755)
        env = dict(self.env, PATH=str(slow) + ':' + self.env['PATH'])
        p = subprocess.Popen(['bash', str(self.src / 'install.sh')], env=env, text=True,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        end = time.time() + 20
        while not marker.exists():
            if p.poll() is not None:
                self.fail('install finished before interruption: %r' % (p.communicate(),))
            self.assertLess(time.time(), end)
            time.sleep(0.02)
        p.send_signal(sig)
        p.communicate(timeout=20)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.ptr('current'), before)
        self.assertEqual((self.rt / 'RELEASE').read_text().strip(), before)
        self.wait(self.engine_running, 'old engine still running')
        return before

    def test_interrupted_upgrade_sigterm_keeps_working_version(self):
        self.interrupt_upgrade(signal.SIGTERM)
        self.assertEqual([p.name for p in (self.flash / 'releases').iterdir() if p.name.startswith('.')], [])

    def test_interrupted_upgrade_sigkill_keeps_working_version_and_next_install_cleans_up(self):
        before = self.interrupt_upgrade(signal.SIGKILL)
        time.sleep(1.2)  # orphaned cp finishes into the abandoned staging dir
        self.assertTrue(any(p.name.startswith('.staging.') for p in (self.flash / 'releases').iterdir()))
        r = self.install()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual([p.name for p in (self.flash / 'releases').iterdir() if p.name.startswith('.')], [])
        self.assertEqual(self.ptr('previous'), before)

    def test_rollback_and_undo(self):
        self.install()
        self.array_up()
        v1 = self.ptr('current')
        cfg, _ = self.seed_config_and_history()
        self.bump('0.4.5-dev')
        self.install()
        v2 = self.ptr('current')
        r = self.wm('rollback')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.ptr('current'), self.ptr('previous')), (v1, v2))
        self.assertEqual((self.rt / 'RELEASE').read_text().strip(), v1)
        self.wait(self.engine_running, 'engine after rollback')
        self.assertEqual(digest(self.flash / 'config'), cfg)
        self.wm('rollback')
        self.assertEqual(self.ptr('current'), v2)

    def test_rollback_to_pre_smart_release_and_undo(self):
        # Emulate a legitimate older release without the collector added in v0.4.5.
        self.assertEqual(self.install().returncode, 0)
        self.array_up()
        self.wait(self.engine_running, 'initial engine')
        old = self.ptr('current')
        old_dir = self.flash / 'releases' / old
        (old_dir / 'VERSION').write_text('0.4.4-dev\n')
        (old_dir / 'watchman_smart.sh').unlink()
        self.bump('0.4.6-dev')
        self.assertEqual(self.install().returncode, 0)
        newer = self.ptr('current')
        self.wait(self.engine_running, 'upgraded engine')
        r = self.wm('rollback')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.ptr('current'), self.ptr('previous')), (old, newer))
        self.assertEqual((self.rt / 'RELEASE').read_text().strip(), old)
        self.assertFalse((self.rt / 'watchman_smart.sh').exists())
        self.wait(self.engine_running, 'older pre-SMART engine')
        r = self.wm('rollback')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.rt / 'RELEASE').read_text().strip(), newer)
        self.assertTrue((self.rt / 'watchman_smart.sh').exists())
        self.wait(self.engine_running, 'upgraded engine restored')

    def test_real_v044_rollback_with_smart_config_survives_boot_and_undo(self):
        # Use byte-for-byte real pre-SMART v0.4.4 source from the local repo.
        # This specifically catches an old engine rejecting smart_enabled,
        # even though its supervisor and runtime symlinks appear healthy.
        import json
        old_source = self.t / 'real-v044'
        old_source.mkdir()
        for name in ('watchman.sh', 'watchman_engine.sh',
                     'watchman_local_metrics.sh', 'watchmanctl.sh',
                     'install.sh', 'VERSION'):
            result = subprocess.run(['git', '-C', str(HERE), 'show', '3b048bc:' + name],
                                    capture_output=True)
            if result.returncode:
                self.skipTest('Historical v0.4.4 Git commit not available in this source bundle')
            (old_source / name).write_bytes(result.stdout)
        r = self.install(old_source)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.array_up()
        self.wait(self.engine_running, 'real v0.4.4 engine')
        config = self.flash / 'config/watchman.json'
        original = dict(version='0.4.2', disks=['disk1'], containers=[], smart_enabled=True)
        config.write_text(json.dumps(original))
        r = self.install()
        self.assertEqual(r.returncode, 0, r.stderr)
        newer, older = self.ptr('current'), self.ptr('previous')
        self.wait(self.engine_running, 'v0.4.5 engine')
        r = self.wm('rollback')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.ptr('current'), older)
        self.assertTrue(self.engine_running())
        self.assertEqual(self.status_text(), 'running')
        self.assertNotIn('smart_enabled', json.loads(config.read_text()))
        self.assertEqual(json.loads((self.flash / 'config/watchman.json.pre-smart-rollback').read_text()), original)
        self.assertTrue((self.flash / 'controller.sh').exists())
        # Re-run the persisted boot hook in the fake root, not the real NAS.
        self.assertEqual(self.wm('stop').returncode, 0)
        shutil.rmtree(self.rt)
        self.bin.unlink()
        r = subprocess.run(['bash', str(self.flash / 'boot.sh')], env=self.env,
                           capture_output=True, text=True, timeout=20)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.wait(self.engine_running, 'v0.4.4 engine after fake reboot')
        self.assertEqual(self.status_text(), 'running')
        r = self.wm('rollback')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.ptr('current'), newer)
        self.assertTrue((self.rt / 'watchman_smart.sh').exists())
        self.assertEqual(json.loads(config.read_text()), original)
        self.assertFalse((self.flash / 'config/watchman.json.pre-smart-rollback').exists())
        self.wait(self.engine_running, 'new engine after undo')
        self.assertEqual(self.status_text(), 'running')

    def prepare_real_smart_rollback(self):
        # Install the genuine v0.4.4 code first, then upgrade and downgrade.
        # Unlike a renamed v0.4.5 fixture, this exercises the real old config
        # validator and the pinned controller used after downgrade.
        old_src = self.t / 'actual-v044'
        old_src.mkdir()
        for name in ('watchman.sh', 'watchman_engine.sh',
                     'watchman_local_metrics.sh', 'watchmanctl.sh',
                     'install.sh', 'VERSION'):
            out = subprocess.run(['git', '-C', str(HERE), 'show', '3b048bc:' + name],
                                 capture_output=True)
            if out.returncode:
                self.skipTest('Historical v0.4.4 commit is unavailable')
            (old_src / name).write_bytes(out.stdout)
        r = self.install(old_src)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.array_up()
        self.wait(self.engine_running, 'v0.4.4 engine')
        cfg = self.flash / 'config/watchman.json'
        original = dict(version='0.4.2', disks=['disk1'], containers=[],
                        gpu_warn=83, smart_enabled=True)
        cfg.write_text(json.dumps(original))
        r = self.install()
        self.assertEqual(r.returncode, 0, r.stderr)
        modern, legacy = self.ptr('current'), self.ptr('previous')
        r = self.wm('rollback')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.wait(self.engine_running, 'real legacy engine after downgrade')
        self.assertEqual(self.ptr('current'), legacy)
        self.assertTrue((self.flash / 'config/watchman.json.pre-smart-rollback').exists())
        return cfg, original, modern, legacy

    @staticmethod
    def edited_legacy_config(cfg):
        edited = json.loads(cfg.read_text())
        edited['disks'] = ['disk1', 'disk2']
        edited['gpu_warn'] = 78
        edited['ram_warn'] = 87
        cfg.write_text(json.dumps(edited))
        return edited

    def assert_actual_engine(self):
        self.wait(self.engine_running, 'live worker PID')
        pid = int((self.run_dir / 'engine.pid').read_text().strip())
        os.kill(pid, 0)
        self.assertEqual(self.status_text(), 'running')

    def test_legacy_edits_survive_undo_with_saved_smart_preference(self):
        cfg, original, modern, legacy = self.prepare_real_smart_rollback()
        edited = self.edited_legacy_config(cfg)
        r = self.wm('rollback')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('Restored the saved SMART preference', r.stdout)
        self.assertEqual(self.ptr('current'), modern)
        self.assertEqual(json.loads(cfg.read_text()), dict(edited, smart_enabled=True))
        self.assertFalse((self.flash / 'config/watchman.json.pre-smart-rollback').exists())
        self.assertFalse((self.flash / 'config/watchman.json.pre-smart-rollback.cksum').exists())
        self.assert_actual_engine()
        # Repeat downgrade/undo to prove the archive lifecycle can restart.
        r = self.wm('rollback')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.ptr('current'), legacy)
        self.assertEqual(json.loads(cfg.read_text()), edited)
        r = self.wm('rollback')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(cfg.read_text()), dict(edited, smart_enabled=True))
        self.assert_actual_engine()

    def test_legacy_edits_survive_reinstall_with_saved_smart_preference(self):
        cfg, original, modern, legacy = self.prepare_real_smart_rollback()
        edited = self.edited_legacy_config(cfg)
        r = self.install()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('Preserved edited legacy settings', r.stdout)
        self.assertNotEqual(self.ptr('current'), legacy)
        self.assertEqual(json.loads(cfg.read_text()), dict(edited, smart_enabled=True))
        self.assertFalse((self.flash / 'config/watchman.json.pre-smart-rollback').exists())
        self.assertFalse((self.flash / 'config/watchman.json.pre-smart-rollback.cksum').exists())
        self.assert_actual_engine()
        # The new release still retains a usable rollback path to v0.4.4.
        r = self.wm('rollback')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(cfg.read_text()), edited)
        r = self.wm('rollback')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(cfg.read_text()), dict(edited, smart_enabled=True))

    def test_failed_legacy_reinstall_restores_edits_and_archive(self):
        cfg, original, modern, legacy = self.prepare_real_smart_rollback()
        edited = self.edited_legacy_config(cfg)
        active_bytes = cfg.read_bytes()
        archive = self.flash / 'config/watchman.json.pre-smart-rollback'
        hashfile = self.flash / 'config/watchman.json.pre-smart-rollback.cksum'
        archive_bytes, hash_bytes = archive.read_bytes(), hashfile.read_bytes()
        bad = self.t / 'fail-reinstall-start'
        bad.mkdir()
        fired = bad / 'fired'
        stub = bad / 'setsid'
        stub.write_text('#!/bin/sh\nif [ ! -e "%s" ]; then touch "%s"; exit 41; fi\nexec /usr/bin/setsid "$@"\n' % (fired, fired))
        stub.chmod(0o755)
        self.env['PATH'] = str(bad) + ':' + self.env['PATH']
        r = self.install()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('new supervisor failed to start', r.stderr)
        self.assertTrue(fired.exists())
        self.assertEqual(self.ptr('current'), legacy)
        self.assertEqual(cfg.read_bytes(), active_bytes)
        self.assertEqual(archive.read_bytes(), archive_bytes)
        self.assertEqual(hashfile.read_bytes(), hash_bytes)
        self.assert_actual_engine()
        r = self.install()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(cfg.read_text()), dict(edited, smart_enabled=True))
        self.assertFalse(archive.exists())
        self.assertFalse(hashfile.exists())
        self.assert_actual_engine()

    def test_legacy_reinstall_rejects_crashing_new_engine_and_preserves_archive(self):
        cfg, original, modern, legacy = self.prepare_real_smart_rollback()
        edited = self.edited_legacy_config(cfg)
        previous_bytes = cfg.read_bytes()
        archive = self.flash / 'config/watchman.json.pre-smart-rollback'
        saved_bytes = archive.read_bytes()
        source_engine = self.src / 'watchman_engine.sh'
        healthy_engine = source_engine.read_bytes()
        source_engine.write_text('#!/bin/bash\nexit 99\n')
        r = self.install()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('new engine did not stay running', r.stderr)
        self.assertEqual(self.ptr('current'), legacy)
        self.assertEqual(cfg.read_bytes(), previous_bytes)
        self.assertEqual(archive.read_bytes(), saved_bytes)
        self.assert_actual_engine()
        source_engine.write_bytes(healthy_engine)
        r = self.install()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(cfg.read_text()), dict(edited, smart_enabled=True))
        self.assertFalse(archive.exists())
        self.assert_actual_engine()

    def test_invalid_legacy_edit_rejects_undo_and_reinstall_without_changes(self):
        cfg, original, modern, legacy = self.prepare_real_smart_rollback()
        bad_cfg = json.loads(cfg.read_text())
        bad_cfg['disks'] = 'corrupted-list'
        cfg.write_text(json.dumps(bad_cfg))
        before = cfg.read_bytes()
        archive = self.flash / 'config/watchman.json.pre-smart-rollback'
        old_archive = archive.read_bytes()
        r = self.wm('rollback')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.ptr('current'), legacy)
        self.assertEqual(cfg.read_bytes(), before)
        self.assertEqual(archive.read_bytes(), old_archive)
        r = self.install()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('rejects merged configuration', r.stderr)
        self.assertEqual(self.ptr('current'), legacy)
        self.assertEqual(cfg.read_bytes(), before)
        self.assertEqual(archive.read_bytes(), old_archive)

    def test_partial_legacy_archive_rejected_without_switching_release(self):
        cfg, original, modern, legacy = self.prepare_real_smart_rollback()
        self.edited_legacy_config(cfg)
        checksum = self.flash / 'config/watchman.json.pre-smart-rollback.cksum'
        checksum.unlink()
        before = cfg.read_bytes()
        r = self.wm('rollback')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.ptr('current'), legacy)
        self.assertEqual(cfg.read_bytes(), before)
        r = self.install()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('archive is incomplete or invalid', r.stderr)
        self.assertEqual(self.ptr('current'), legacy)
        self.assertEqual(cfg.read_bytes(), before)

    def test_rollback_rejects_missing_smart_from_new_release(self):
        self.assertEqual(self.install().returncode, 0)
        self.array_up()
        self.wait(self.engine_running, 'initial engine')
        old = self.ptr('current')
        (self.flash / 'releases' / old / 'watchman_smart.sh').unlink()
        self.bump('0.4.6-dev')
        self.assertEqual(self.install().returncode, 0)
        newer = self.ptr('current')
        self.wait(self.engine_running, 'upgraded engine')
        r = self.wm('rollback')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.ptr('current'), newer)
        self.assertEqual((self.rt / 'RELEASE').read_text().strip(), newer)
        self.wait(self.engine_running, 'upgraded engine still running')

    def test_rollback_copy_failure_restores_running_release(self):
        self.assertEqual(self.install().returncode, 0)
        self.array_up()
        self.wait(self.engine_running, 'first engine')
        first = self.ptr('current')
        self.bump('0.4.6-dev')
        self.assertEqual(self.install().returncode, 0)
        second = self.ptr('current')
        self.wait(self.engine_running, 'second engine')
        bad = self.t / 'fail-rollback-copy'
        bad.mkdir()
        shim = bad / 'cp'
        shim.write_text('#!/bin/sh\ncase "$*" in *releases/%s/*) exit 71;; esac\nexec /usr/bin/cp "$@"\n' % first)
        shim.chmod(0o755)
        self.env['PATH'] = str(bad) + ':' + self.env['PATH']
        result = self.wm('rollback')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('could not deploy rollback target', result.stderr)
        self.assertEqual((self.ptr('current'), self.ptr('previous')), (second, first))
        self.assertEqual((self.rt / 'RELEASE').read_text().strip(), second)
        self.wait(self.engine_running, 'second engine survives rollback copy failure')

    def test_rollback_start_failure_restores_running_release(self):
        self.assertEqual(self.install().returncode, 0)
        self.array_up()
        self.wait(self.engine_running, 'first engine')
        first = self.ptr('current')
        self.bump('0.4.6-dev')
        self.assertEqual(self.install().returncode, 0)
        second = self.ptr('current')
        self.wait(self.engine_running, 'second engine')
        bad = self.t / 'fail-rollback-start'
        bad.mkdir()
        failed_once = bad / 'failure-marker'
        shim = bad / 'setsid'
        shim.write_text('#!/bin/sh\nif [ ! -e "%s" ]; then touch "%s"; exit 42; fi\nexec /usr/bin/setsid "$@"\n' % (failed_once, failed_once))
        shim.chmod(0o755)
        self.env['PATH'] = str(bad) + ':' + self.env['PATH']
        result = self.wm('rollback')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('rollback supervisor failed to start', result.stderr)
        self.assertTrue(failed_once.exists())
        self.assertEqual((self.ptr('current'), self.ptr('previous')), (second, first))
        self.assertEqual((self.rt / 'RELEASE').read_text().strip(), second)
        self.wait(self.engine_running, 'second engine survives rollback start failure')

    def test_reboot_redeploys_from_flash_and_waits(self):
        self.install()
        self.wm('stop')
        for d in (self.rt, self.run_dir):          # RAM is wiped by a reboot
            shutil.rmtree(d, ignore_errors=True)
        self.bin.unlink()
        boot = subprocess.run(['bash', str(self.flash / 'boot.sh')], env={k: v for k, v in self.env.items() if k != 'WATCHMAN_ROOT'},
                              timeout=20)
        self.assertEqual(boot.returncode, 0)
        self.wait(lambda: self.bin.exists() and (self.rt / 'event' / 'stopping').exists(), 'runtime redeployed')
        self.wait(lambda: 'waiting' in self.status_text(), 'supervisor waiting after boot')
        self.assertFalse(self.state.exists())
        self.array_up()
        self.wait(self.engine_running, 'engine after array start')

    def test_disable_survives_events_until_enabled(self):
        self.install()
        self.array_up()
        self.wait(self.engine_running, 'engine')
        self.wm('disable')
        self.assertEqual(self.supervisors(), [])
        subprocess.run(['bash', str(self.rt / 'event' / 'disks_mounted')], env=self.env, timeout=10)
        time.sleep(1)
        self.assertEqual(self.supervisors(), [])
        self.assertIn('disabled', self.wm('status').stdout)
        self.wm('enable')
        self.wait(self.engine_running, 'engine after enable')

    def test_uninstall_keeps_data_then_purge_removes_it(self):
        self.install()
        self.array_up()
        self.wait(self.engine_running, 'engine')
        cfg, _ = self.seed_config_and_history()
        r = self.wm('uninstall', '--yes')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.root / 'boot/config/go').read_text(), GO_ORIGINAL)
        for p in (self.rt, self.bin, self.run_dir, self.flash / 'releases', self.flash / 'boot.sh', self.flash / 'current'):
            self.assertFalse(p.exists(), p)
        self.assertEqual(self.supervisors(), [])
        self.assertEqual(digest(self.flash / 'config'), cfg)
        self.assertTrue((self.state / 'state.json').exists())
        self.install()
        self.wm('uninstall', '--purge', '--yes')
        self.assertFalse(self.flash.exists())
        self.assertFalse(self.state.exists())
        self.assertEqual((self.root / 'boot/config/go').read_text(), GO_ORIGINAL)

    # ---- installer bug regressions (Nov 15): boot modes and failed activation ----
    def test_install_upgrade_uninstall_preserve_go_executable_mode(self):
        go = self.root / 'boot/config/go'
        go.chmod(0o755)
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual(stat.S_IMODE(go.stat().st_mode), 0o755)
        self.bump('0.4.6-dev')
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual(stat.S_IMODE(go.stat().st_mode), 0o755)
        self.assertEqual((self.root / 'boot/config/go.watchman-backup').read_text(), GO_ORIGINAL)
        self.assertEqual(self.wm('uninstall', '--yes').returncode, 0)
        self.assertEqual(stat.S_IMODE(go.stat().st_mode), 0o755)
        self.assertEqual(go.read_text(), GO_ORIGINAL)

    def test_failed_autostart_update_keeps_original_pointers_and_runtime(self):
        self.assertEqual(self.install().returncode, 0)
        self.array_up()
        self.wait(self.engine_running, 'old engine running')
        old = self.ptr('current')
        old_prev = self.ptr('previous')
        # Simulate an admin removing the autostart entry between upgrades.
        go = self.root / 'boot/config/go'
        go.write_text(GO_ORIGINAL)
        bad = self.t / 'fail-go'
        bad.mkdir()
        shim = bad / 'mktemp'
        shim.write_text('#!/bin/sh\ncase "$*" in *"/boot/config/go.XXXXXX"*) exit 73;; esac\nexec /usr/bin/mktemp "$@"\n')
        shim.chmod(0o755)
        self.env['PATH'] = str(bad) + ':' + self.env['PATH']
        self.bump('0.4.6-dev')
        r = self.install()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('could not add autostart line', r.stderr)
        self.assertEqual(self.ptr('current'), old)
        self.assertEqual(self.ptr('previous'), old_prev)
        self.assertEqual((self.rt / 'RELEASE').read_text().strip(), old)
        self.assertEqual(go.read_text(), GO_ORIGINAL)
        self.wait(self.engine_running, 'old engine survives failed go update')

    def test_failed_new_supervisor_restores_prior_release_and_runtime(self):
        self.assertEqual(self.install().returncode, 0)
        self.array_up()
        self.wait(self.engine_running, 'old engine running')
        old = self.ptr('current')
        prior = self.ptr('previous')
        self.bump('0.4.6-dev')
        bad = self.t / 'fail-once'
        bad.mkdir()
        hit = bad / 'failed-once'
        shim = bad / 'setsid'
        shim.write_text('#!/bin/sh\nif [ ! -e "%s" ]; then touch "%s"; exit 42; fi\nexec /usr/bin/setsid "$@"\n' % (hit, hit))
        shim.chmod(0o755)
        self.env['PATH'] = str(bad) + ':' + self.env['PATH']
        r = self.install()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('new supervisor failed to start', r.stderr)
        self.assertTrue(hit.exists(), 'failure injection was triggered')
        self.assertEqual(self.ptr('current'), old)
        self.assertEqual(self.ptr('previous'), prior)
        self.assertEqual((self.rt / 'RELEASE').read_text().strip(), old)
        self.wait(self.engine_running, 'old engine restarted after failed activation')

    def test_failed_runtime_copy_preserves_existing_rollback_target(self):
        self.assertEqual(self.install().returncode, 0)
        self.array_up()
        self.wait(self.engine_running, 'first engine')
        first = self.ptr('current')
        self.bump('0.4.6-dev')
        self.assertEqual(self.install().returncode, 0)
        second = self.ptr('current')
        self.assertEqual(self.ptr('previous'), first)
        self.bump('0.4.7-dev')
        bad = self.t / 'fail-runtime-copy'
        bad.mkdir()
        shim = bad / 'cp'
        shim.write_text('#!/bin/sh\ncase "$*" in *releases/0.4.7-dev-*/watchman_smart.sh*) exit 73;; esac\nexec /usr/bin/cp "$@"\n')
        shim.chmod(0o755)
        self.env['PATH'] = str(bad) + ':' + self.env['PATH']
        r = self.install()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('runtime deployment failed', r.stderr)
        self.assertEqual(self.ptr('current'), second)
        self.assertEqual(self.ptr('previous'), first)
        self.assertEqual((self.rt / 'RELEASE').read_text().strip(), second)
        self.wait(self.engine_running, 'second engine restored')

    def test_report_with_array_stopped_creates_nothing(self):
        self.install()
        (self.root / 'mnt/user/appdata').mkdir()
        r = self.wm('report')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('measured snapshot', r.stdout)
        self.assertFalse(self.state.exists())

    # ---- auto-reload on saved configuration ----
    def engine_pid(self):
        p = self.run_dir / 'engine.pid'
        return p.read_text().strip() if p.exists() else None

    def engine_env_var(self, pid, name):
        env = Path('/proc/%s/environ' % pid).read_bytes().split(b'\0')
        for item in env:
            if item.startswith(name.encode() + b'='):
                return item.split(b'=', 1)[1].decode()
        return None

    def log_text(self):
        p = self.root / 'var/log/watchman.log'
        return p.read_text() if p.exists() else ''

    def test_saved_config_reloads_engine_but_not_supervisor(self):
        self.install()
        self.array_up()
        self.wait(self.engine_running, 'engine')
        sup = self.supervisors()
        first = self.engine_pid()
        self.assertIsNone(self.engine_env_var(first, 'WATCHMAN_DISKS'))   # no config yet (the JohnsVault case)
        (self.flash / 'config/watchman.json').write_text('{"version":"0.4.2","disks":["disk1"],"containers":["ollama"]}\n')
        self.wait(lambda: self.engine_pid() not in (None, first), 'engine reload')
        new = self.engine_pid()
        self.wait(lambda: self.engine_env_var(new, 'WATCHMAN_DISKS') == '["disk1"]', 'new engine has saved disks')
        self.assertEqual(self.engine_env_var(new, 'WATCHMAN_CONTAINERS'), '["ollama"]')
        self.assertEqual(self.supervisors(), sup, 'supervisor must not restart')
        self.assertIn('configuration changed; reloading engine', self.log_text())
        self.assertIn('Watchman engine stopped cleanly.', self.log_text())

    def test_invalid_config_keeps_running_engine_until_fixed(self):
        self.install()
        self.array_up()
        self.wait(self.engine_running, 'engine')
        first = self.engine_pid()
        (self.flash / 'config/watchman.json').write_text('{"version":"0.4.2","disks":"not-a-list","containers":[]}\n')
        self.wait(lambda: 'configuration change is invalid' in self.log_text(), 'invalid config logged')
        time.sleep(1)
        self.assertEqual(self.engine_pid(), first)
        self.assertEqual(self.log_text().count('configuration change is invalid'), 1, 'logged once, not every poll')
        (self.flash / 'config/watchman.json').write_text('{"version":"0.4.2","disks":["disk1"],"containers":[]}\n')
        self.wait(lambda: self.engine_pid() not in (None, first), 'reload after fix')

    def test_install_refuses_without_go_file(self):
        (self.root / 'boot/config/go').rename(self.t / 'go.saved')
        r = self.install()
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse((self.flash / 'current').exists())
        (self.t / 'go.saved').rename(self.root / 'boot/config/go')


if __name__ == '__main__':
    unittest.main()
