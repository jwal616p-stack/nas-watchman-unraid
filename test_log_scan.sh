#!/usr/bin/env bash
# Offline syslog-scan regression: real Unraid 7.3 sshd line shapes, fixture files only, no Discord.
# Every scan runs in a NEW bash process (like an engine restart) that only has the saved cursor.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export WATCHMAN_STATE_DIR=$T/state WATCHMAN_SYSLOG=$T/syslog WATCHMAN_BOOT_ID_FILE=$T/boot_id
export WATCHMAN_WEBHOOK_FILE=$T/none WATCHMAN_DISKS_INI=$T/none WATCHMAN_VAR_INI=$T/none
export WATCHMAN_CONTAINERS='[]' WATCHMAN_DISKS='[]' NOTICES=$T/notices
mkdir -p "$T/state"; : > "$NOTICES"; echo boot-A > "$T/boot_id"
sed '/^collect || exit 1$/,$d' "$ROOT/watchman_engine.sh" > "$T/defs.sh"
scan() {  # fresh process each time
  bash -c 'f=$1; set --; source "$f"; send() { [[ ${FAIL_SEND:-0} == 1 ]] && return 1; printf "%s\n" "$1" >> "$NOTICES"; }; scan_logs' _ "$T/defs.sh"
}
login() {  # exactly what Unraid 7.3.2 sshd writes for one key login
  local p=$((RANDOM+1000))
  printf 'Nov 14 17:00:51 JohnsVault sshd-session[%s]: Connection from 10.0.0.9 port 35846 on 10.0.0.217 port 22 rdomain ""\n' $p
  printf 'Nov 14 17:00:51 JohnsVault sshd-session[%s]: Accepted key ED25519 SHA256:x found at /root/.ssh/authorized_keys:1\n' $p
  printf 'Nov 14 17:00:51 JohnsVault sshd-session[%s]: Postponed publickey for root from 10.0.0.9 port 35846 ssh2 [preauth]\n' $p
  printf 'Nov 14 17:00:51 JohnsVault sshd-session[%s]: Accepted key ED25519 SHA256:x found at /root/.ssh/authorized_keys:1\n' $p
  printf 'Nov 14 17:00:51 JohnsVault sshd-session[%s]: Accepted publickey for root from 10.0.0.9 port 35846 ssh2: ED25519 SHA256:x\n' $p
  printf 'Nov 14 17:00:51 JohnsVault sshd-session[%s]: pam_unix(sshd:session): session opened for user root(uid=0) by (uid=0)\n' $p
}
notices() { grep -c '^NAS Watchman - new system-log events' "$NOTICES" || true; }
expect() { local n; n=$(notices); [[ $n -eq $1 ]] || { echo "FAIL ($2): expected $1 notices, got $n"; cat "$NOTICES"; exit 1; }; }
has() { grep -Fq -- "$1" "$NOTICES" || { echo "FAIL: missing: $1"; cat "$NOTICES"; exit 1; }; }

{ login; login; } > "$T/syslog"
scan; expect 0 'first run starts at end of log'
scan; expect 0 'restart: nothing new'
echo 'PASS: first run does not replay existing log; restart is quiet'

login >> "$T/syslog"; scan; expect 1 'one login'
has 'LOGIN NOTICE: 1 successful SSH login(s).'
scan; scan; expect 1 'two restarts after delivery'
echo 'PASS: one Unraid key login (3 "Accepted" lines) counted once; not replayed across restarts'

{ login; login; login; } >> "$T/syslog"
FAIL_SEND=1 scan || true; expect 1 'delivery failed'
FAIL_SEND=1 scan || true; expect 1 'delivery failed again'
scan; expect 2 'delivered after Discord recovers'
has 'LOGIN NOTICE: 3 successful SSH login(s).'
scan; expect 2 'no duplicate after late delivery'
echo 'PASS: failed delivery holds events; delivered once with the right count'

printf 'Nov 14 17:05:00 JohnsVault sshd-session[42]: Failed password for root from 10.0.0.66 port 1 ssh2\n' >> "$T/syslog"
scan; expect 3 'failed login'
has 'AUTH NOTICE: 1 failed/invalid-user log entries'
echo 'PASS: failed login reported'

login >> "$T/syslog"; echo boot-B > "$T/boot_id"
scan; expect 3 'new boot starts at end'
login >> "$T/syslog"; scan; expect 4 'after reboot only new events'
has 'LOGIN NOTICE: 1 successful SSH login(s).'
echo 'PASS: after a reboot, older log lines are not replayed'

mv "$T/syslog" "$T/syslog.1"; login > "$T/syslog"
scan; expect 5 'rotation'
has 'Log rotated/truncated'
scan; expect 5 'no repeat after rotation'
echo 'PASS: log rotation reads the new file once'
echo '6 log-scan scenarios passed; send() intercepted locally.'
