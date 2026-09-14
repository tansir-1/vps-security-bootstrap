#!/usr/bin/env python3
from pathlib import Path
import hashlib, re
root = Path(__file__).resolve().parents[1]
src = (root / 'vps-security.sh').read_text(encoding='utf-8')
installer = (root / 'install.sh').read_text(encoding='utf-8')
builder = (root / 'tools' / 'build-copy-paste.sh').read_text(encoding='utf-8')
version = (root / 'VERSION').read_text(encoding='utf-8').strip()
assert f'VERSION="{version}"' in src
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
