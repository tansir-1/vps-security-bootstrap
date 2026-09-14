#!/usr/bin/env python3
from pathlib import Path
import hashlib, re
root = Path(__file__).resolve().parents[1]
src = (root / 'vps-security.sh').read_text(encoding='utf-8')
installer = (root / 'install.sh').read_text(encoding='utf-8')
builder = (root / 'tools' / 'build-copy-paste.sh').read_text(encoding='utf-8')
version = (root / 'VERSION').read_text(encoding='utf-8').strip()
assert f'VERSION="{version}"' in src
assert 'detect_platform()' in src
assert 'local ID="" ID_LIKE="" VERSION_ID="" PRETTY_NAME="" VERSION=""' in src
assert 'debian|ubuntu' in src
assert 'rhel|centos|rocky|almalinux|ol|fedora|amzn' in src
assert 'pkg_upgrade_system()' in src
assert 'dnf -y upgrade --refresh' in src
assert 'dnf -y upgrade --releasever=latest' in src
assert 'yum -y update' in src
assert 'allow_ssh_port_in_selinux()' in src
assert 'policycoreutils-python-utils' in src
assert 'choose_full_step_action()' in src
assert 'FULL_SKIP_PREFLIGHT="1"' in src
assert '1. 执行（默认）' in src
assert '2. 跳过' in src
assert 'ipv6_toggle_menu()' in src
assert 'net.ipv6.conf.all.disable_ipv6 = $value' in src
assert 'restore_ipv6_sysctl_backup()' in src
assert 'is_custom_iptables_active()' in src
assert src.index('is_custom_nftables_active') < src.index('elif is_ufw_installed')
assert 'firewall-cmd --get-zone-of-interface' in src
assert 'UFW 未启用，IPv6 未受 UFW 实际保护' in src
fail2ban_update = src[src.index('update_fail2ban_ssh_port()'):src.index('detect_business_services()')]
assert 'fail2ban-client get sshd port' not in fail2ban_update
assert fail2ban_update.index('fail2ban-client -t') < fail2ban_update.index('systemctl restart fail2ban')
assert fail2ban_update.index('systemctl restart fail2ban') < fail2ban_update.index('fail2ban-client status sshd')
assert '为避免误删你原本手工创建的规则' in src
assert 'had-no-authorized-keys' in src
assert 'mktemp /tmp/vps-security-bootstrap.' in installer
assert 'mktemp /tmp/vps-security-bootstrap-v$VERSION.' in builder
m = re.search(r'EXPECTED_SHA256="([0-9a-f]{64})"', installer)
assert m
assert m.group(1) == hashlib.sha256((root / 'vps-security.sh').read_bytes()).hexdigest()
print('static safety tests passed')
