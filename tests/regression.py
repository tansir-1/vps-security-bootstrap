#!/usr/bin/env python3
"""Execute actual Bash functions with isolated files and mocked system commands.

No top-level bootstrap code is sourced. Never runs a package manager, sshd,
firewall, or sysctl against the host. BASH_BIN may select a portable Bash.
"""
from pathlib import Path
import os
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'vps-security.sh').read_text(encoding='utf-8')
FUNCTIONS = '\n'.join(re.findall(
    r'^\w+\(\) \{[^\n]*\}\s*$|^\w+\(\) \{\n.*?^\}', SOURCE, re.M | re.S))
SETUP = r'''
set -uo pipefail
exec 3</dev/null 4>/dev/null
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
LOG_FILE="$work/log"
STATE_FILE="$work/state.env"
TXN_ROOT="$work/transactions"
mkdir -p "$TXN_ROOT"
say() { :; }
log() { :; }
'''
CASES = {
    'systemd inactive state is not duplicated': r'''
systemctl() { echo inactive; return 3; }
[[ "$(_unit_active_state ssh.socket)" == inactive ]]
''',
    'systemd disabled state is not duplicated': r'''
systemctl() { echo disabled; return 1; }
[[ "$(_unit_enabled_state ssh.socket)" == disabled ]]
''',
    'leading-zero ports normalize as decimal': r'''
[[ "$(normalize_port_spec 00080)" == 80 ]] &&
[[ "$(normalize_port_spec 0080-0090)" == 80:90 ]] &&
! normalize_port_spec 9999999999999999999999999
''',
    'scoped UFW allow does not count as global allow': r'''
is_ufw_installed() { return 0; }
ufw() { printf 'Status: active\n22/tcp ALLOW IN 192.0.2.1\n'; }
[[ "$(ufw_rule_state 22 tcp)" != allow ]]
''',
    'UFW overlapping reject is detected': r'''
is_ufw_installed() { return 0; }
ufw() { printf 'Status: active\n20:30/tcp REJECT IN Anywhere\n'; }
[[ "$(ufw_rule_state 22 tcp)" == deny ]]
''',
    'failed UFW write propagates even in a conditional': r'''
ufw_rule_state() { echo none; }
ufw() { return 1; }
if ufw_safe_allow 22 tcp SSH 1; then exit 1; fi
''',
    'firewalld conflict cannot report success': r'''
firewalld_zone() { echo public; }
firewalld_rich_conflict() { return 0; }
choose_num() { printf -v "$1" 1; }
if firewalld_allow_safe 22 tcp SSH; then exit 1; fi
''',
    'firewalld runtime-only allow gains persistent rule': r'''
firewalld_zone() { echo public; }
firewalld_rich_conflict() { return 1; }
firewall-cmd() { printf '%s\n' "$*" >> "$work/fw"; return 0; }
firewalld_allow_safe 22 tcp SSH &&
grep -q -- '--permanent.*--add-port=22/tcp' "$work/fw"
''',
    'failed SSH snapshot never becomes a transaction': r'''
SSHD_CONFIG="$work/missing-config"
save_state() { echo called > "$work/saved"; }
if begin_ssh_transaction 22 22222 >/dev/null 2>&1; then exit 1; fi
[[ ! -e "$work/saved" ]]
''',
    'new SSH transaction cannot overwrite pending recovery': r'''
SSH_TXN_DIR="$work/pending"
mkdir -p "$SSH_TXN_DIR"
SSHD_CONFIG="$work/sshd_config"
echo 'Port 22' > "$SSHD_CONFIG"
save_state() { :; }
if begin_ssh_transaction 22 22222 >/dev/null 2>&1; then exit 1; fi
[[ "$SSH_TXN_DIR" == "$work/pending" ]]
''',
    'managed SSH block preserves root login policy': r'''
SSHD_CONFIG="$work/sshd_config"
MANAGED_BEGIN='# BEGIN VPS-SECURITY-BOOTSTRAP'
MANAGED_END='# END VPS-SECURITY-BOOTSTRAP'
echo 'PermitRootLogin no' > "$SSHD_CONFIG"
comment_existing_port_directives() { :; }
write_sshd_managed_block 22222 1 &&
! grep -q '^PermitRootLogin prohibit-password' "$SSHD_CONFIG"
''',
    'IPv6 rollback restores saved runtime values without global reload': r'''
IPV6_SYSCTL_FILE="$work/ipv6.conf"
echo changed > "$IPV6_SYSCTL_FILE"
printf 'net.ipv6.conf.all.disable_ipv6=0\nnet.ipv6.conf.default.disable_ipv6=1\n' > "$work/runtime.conf"
sysctl() { printf '%s\n' "$*" >> "$work/sysctl"; }
restore_ipv6_sysctl_backup "$work" &&
[[ ! -f "$IPV6_SYSCTL_FILE" ]] &&
grep -q -- '-w net.ipv6.conf.all.disable_ipv6=0' "$work/sysctl" &&
grep -q -- '-w net.ipv6.conf.default.disable_ipv6=1' "$work/sysctl" &&
! grep -q -- '--system' "$work/sysctl"
''',
    'failed managed SSH write propagates to caller': r'''
remove_managed_block() { return 1; }
if write_sshd_managed_block 22222 1; then exit 1; fi
''',
    'firewalld service-wide rejection blocks SSH change': r'''
firewalld_zone() { echo public; }
firewall-cmd() { echo 'rule family="ipv4" service name="ssh" reject'; }
firewalld_rich_conflict 22 tcp
''',
    'state file is atomically replaced': r'''
BASE_DIR="$work"
SSH_PORT=22222
save_state &&
grep -q '^SSH_PORT=22222$' "$STATE_FILE" &&
[[ "$(find "$work" -name '.state.*' | wc -l)" == 0 ]]
''',
    'inactive UFW saved denial is detected': r'''
is_ufw_installed() { return 0; }
ufw() {
    if [[ "$1" == status ]]; then echo 'Status: inactive';
    else echo 'ufw deny 22/tcp'; fi
}
[[ "$(ufw_rule_state 22 tcp)" == deny ]]
''',
    'inactive complex UFW rejection requires review': r'''
is_ufw_installed() { return 0; }
ufw() {
    if [[ "$1" == status ]]; then echo 'Status: inactive';
    else echo 'ufw reject from 192.0.2.1 to any port 22 proto tcp'; fi
}
[[ "$(ufw_rule_state 22 tcp)" == deny ]]
''',
    'permanent firewalld rejection requires review': r'''
firewalld_zone() { echo public; }
firewall-cmd() {
    if [[ "$*" == *--permanent* ]]; then echo 'rule service name="ssh" reject'; fi
    return 0
}
firewalld_rich_conflict 22 tcp
''',
    'terminal EOF exits instead of accepting default yes': r'''
ask answer prompt
exit 1
''',
}

failed = 0
for name, body in CASES.items():
    result = subprocess.run([os.environ.get('BASH_BIN', 'bash')],
                            input=FUNCTIONS + '\n' + SETUP + body,
                            text=True, encoding='utf-8', capture_output=True,
                            timeout=15)
    # EOF is expected to terminate the whole child with a nonzero status.
    passed = result.returncode == (2 if name.startswith('terminal EOF') else 0)
    print(f'{"PASS" if passed else "FAIL"}: {name}')
    if not passed:
        failed += 1
        print(result.stderr[-1200:], end='')
print(f'{len(CASES) - failed}/{len(CASES)} regression tests passed')
sys.exit(bool(failed))
