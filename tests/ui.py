#!/usr/bin/env python3
"""Run only terminal renderers with sample data; never starts the bootstrap."""
from pathlib import Path
import os
import re
import shlex
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'vps-security.sh').read_text(encoding='utf-8')
FUNCTIONS = '\n'.join(re.findall(
    r'^\w+\(\) \{[^\n]*\}\s*$|^\w+\(\) \{\n.*?^\}', SOURCE, re.M | re.S))
ANSI = re.compile(r'\x1b\[[0-9;]*[A-Za-z]')
SAMPLE = {
    'get_os_pretty': 'Debian GNU/Linux 12', 'hostname': 'debian-vps',
    'get_ipv4': '192.0.2.10', 'get_uptime_short': '2 days, 4 hours',
    'status_ipv6': '已启用；无公网 IPv6 地址',
    'status_ssh_port': '32456（高位）', 'status_password_auth': '已关闭',
    'status_ed25519_key': '已配置（1 把）', 'status_root_password': '已设置',
    'status_key_test': '已确认成功', 'status_keepalive': '未开启',
    'status_firewall': 'UFW 已启用', 'status_fail2ban': '运行中',
    'status_system_update': '已执行', 'status_auto_updates': '已开启（unattended-upgrades）',
    'status_public_listeners': '4 项', 'status_preflight': '已扫描（保护 4 项）',
    'status_docker': '未安装', 'status_docker_firewall': '不适用',
    'status_ipv6_firewall': '无公网 IPv6，无需检查',
    'status_report': '已生成', 'status_audit': '已执行',
    'status_backup': '已备份', 'status_port_manager': 'UFW',
    'status_reboot_required': '无需重启',
}


def run(body, *, width=80, color='never', sample=False):
    setup = f'''set -uo pipefail
exec 4>&1
exec 3<<<"0"
TERM=xterm-256color
unset NO_COLOR
CLI_AUDIT=0
COLUMNS={width}
VPS_UI_COLOR={shlex.quote(color)}
PKG_MANAGER=apt
VERSION="$(sed -n 's/^VERSION="\\(.*\\)"/\\1/p' {shlex.quote(str(ROOT / 'vps-security.sh').replace(chr(92), '/'))})"
APP_NAME="VPS Security Bootstrap v$VERSION"
'''
    if sample:
        setup += '\n'.join(f'{name}() {{ printf "%s" {shlex.quote(value)}; }}'
                           for name, value in SAMPLE.items()) + '\n'
    result = subprocess.run([os.environ.get('BASH_BIN', 'bash')],
                            input=FUNCTIONS + '\n' + setup + '\nui_init\n' + body,
                            text=True, encoding='utf-8', capture_output=True, timeout=20)
    if result.returncode:
        raise AssertionError(result.stderr or f'Bash exited {result.returncode}')
    return result.stdout


class TerminalUI(unittest.TestCase):
    @unittest.skipUnless(os.name == 'posix', 'POSIX pseudo-terminal test runs in Linux CI')
    def test_real_tty_auto_color_and_opt_out(self):
        import errno
        import fcntl
        import pty
        import struct
        import termios

        for disable in (False, True):
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 80, 0, 0))
            child = subprocess.Popen([os.environ.get('BASH_BIN', 'bash')],
                                     stdin=subprocess.PIPE, stdout=slave, stderr=subprocess.PIPE)
            os.close(slave)
            script = FUNCTIONS + '\nexec 4>&1\nTERM=xterm\nCLI_AUDIT=0\nVPS_UI_COLOR=auto\nunset NO_COLOR\n'
            if disable:
                script += 'NO_COLOR=\n'
            script += 'ui_init\nsay "✅ 完成"\n'
            _, errors = child.communicate(script.encode('utf-8'), timeout=10)
            output = b''
            try:
                while True:
                    data = os.read(master, 4096)
                    if not data:
                        break
                    output += data
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
            finally:
                os.close(master)
            self.assertEqual(child.returncode, 0, errors.decode('utf-8'))
            self.assertEqual(b'\x1b[32m' in output, not disable)

    def test_redirected_auto_has_no_ansi(self):
        self.assertNotIn('\x1b', run('say "✅ 完成"', color='auto'))

    def test_forced_color_has_reset(self):
        self.assertIn('\x1b[32m[OK] 完成\x1b[0m', run('say "✅ 完成"', color='always'))

    def test_no_color_even_when_empty_overrides_force(self):
        self.assertNotIn('\x1b', run('NO_COLOR=; ui_init; say "✅ 完成"', color='always'))

    def test_dumb_terminal_is_plain(self):
        self.assertNotIn('\x1b', run('TERM=dumb; ui_init; ui_heading 标题', color='always'))

    def test_audit_is_plain_even_when_forced(self):
        self.assertNotIn('\x1b', run('CLI_AUDIT=1; ui_init; say "⚠️ 检查"', color='always'))

    def test_unicode_cell_width(self):
        self.assertEqual(run("ui_display_width 'SSH 端口：32456（高位）'"), '23')

    def test_narrow_pairs_stack_without_truncation(self):
        self.assertEqual(run("ui_pair '左侧状态完整' '右侧状态完整'", width=48),
                         '  左侧状态完整\n  右侧状态完整\n')

    def test_long_values_stack_instead_of_disappearing(self):
        value = '很长的配置路径' * 10
        output = run(f'ui_pair {shlex.quote(value)} 右侧状态')
        self.assertIn(value, output)
        self.assertEqual(len(output.splitlines()), 2)

    def test_untrusted_terminal_controls_are_not_executed(self):
        self.assertEqual(run("say $'主机\\033[31m\\007\\r名称'"), '主机[31m名称\n')

    def test_backslash_is_literal(self):
        self.assertEqual(run(r"say '路径\n不是换行'"), '路径\\n不是换行\n')

    def test_default_choice_does_not_change(self):
        self.assertTrue(run('exec 3<<<""; choose_num result 请选择 "1 2 0" 0; printf "RESULT=%s" "$result"').endswith('RESULT=0'))

    def test_explicit_choice_does_not_change(self):
        self.assertTrue(run('exec 3<<<"2"; choose_num result 请选择 "1 2 0" 0; printf "RESULT=%s" "$result"').endswith('RESULT=2'))

    def test_main_menu_keeps_all_original_choices(self):
        output = run('main_menu', sample=True)
        for label in ('通用安全开荒', '业务端口保护预检 / 重新扫描',
                      'Docker 安全检查', '高级设置', 'IPv6 开启 / 关闭', '退出工具'):
            self.assertIn(label, output)
        self.assertIn('当前 SSH 连接保持开启', output)

    def test_all_original_statuses_remain_visible(self):
        output = run('show_security_status', sample=True)
        for label in ('SSH 端口', 'SSH 密码认证', 'ED25519 公钥', 'root 密码',
                      '密钥登录测试', 'SSH KeepAlive', '主机防火墙', 'Fail2ban',
                      '系统更新', '自动安全更新', '公网监听', '业务端口保护',
                      'Docker：', 'Docker 防火墙', 'IPv6 防火墙', '安全检查报告',
                      '只读安全审计', '配置备份', '端口防火墙管理', '系统重启'):
            self.assertIn(label, output)
        for value in SAMPLE.values():
            if value not in (SAMPLE['get_os_pretty'], SAMPLE['hostname'], SAMPLE['get_ipv4'],
                             SAMPLE['get_uptime_short'], SAMPLE['status_ipv6']):
                self.assertIn(value, output)

    def test_colors_do_not_change_content(self):
        plain = run('main_menu', sample=True)
        colored = ANSI.sub('', run('main_menu', sample=True, color='always'))
        self.assertEqual(plain, colored)

    def test_rule_width_has_bounds(self):
        self.assertEqual(len(run('ui_rule', width=48).strip()), 48)
        self.assertEqual(len(run('ui_rule', width=999).strip()), 88)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--preview':
        width = int(sys.argv[2]) if len(sys.argv) > 2 else 80
        print(run('main_menu', width=width, color='always', sample=True), end='')
    else:
        unittest.main()
