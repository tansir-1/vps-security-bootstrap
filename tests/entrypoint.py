#!/usr/bin/env python3
"""Keep the public, version-independent launch command stable across releases."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
URL = 'https://raw.githubusercontent.com/tansir-1/vps-security-bootstrap/main/install.sh'
ROOT_COMMAND = f'curl -fsSL {URL} | bash'
SUDO_COMMAND = f'curl -fsSL {URL} | sudo bash'


def text(path):
    return (ROOT / path).read_text(encoding='utf-8')


class PermanentEntrypoint(unittest.TestCase):
    def test_installer_path_and_repository_are_preserved(self):
        installer = text('install.sh')
        self.assertIn('REPO="tansir-1/vps-security-bootstrap"', installer)
        self.assertIn('https://raw.githubusercontent.com/${REPO}/main/install.sh', installer)

    def test_chinese_primary_commands_have_no_version(self):
        chinese = text('README.md').split('<a id="english"></a>', 1)[0]
        commands = re.findall(r'```bash\n(.*?)\n```', chinese, re.S)
        self.assertEqual([cmd.strip() for cmd in commands[:2]], [ROOT_COMMAND, SUDO_COMMAND])

    def test_english_primary_commands_match_chinese(self):
        english = text('README.md').split('<a id="english"></a>', 1)[1]
        commands = re.findall(r'```bash\n(.*?)\n```', english, re.S)
        self.assertEqual([cmd.strip() for cmd in commands[:2]], [ROOT_COMMAND, SUDO_COMMAND])

    def test_agents_document_keeps_the_user_contract(self):
        policy = text('AGENTS.md')
        self.assertIn(ROOT_COMMAND, policy)
        self.assertIn(SUDO_COMMAND, policy)
        self.assertIn('docs/INSTALLATION.md', policy)

    def test_installation_policy_keeps_both_entrypoints(self):
        policy = text('docs/INSTALLATION.md')
        self.assertIn(ROOT_COMMAND, policy)
        self.assertIn(SUDO_COMMAND, policy)

    def test_claude_instructions_point_to_the_shared_contract(self):
        self.assertIn('[AGENTS.md](AGENTS.md)', text('CLAUDE.md'))


if __name__ == '__main__':
    unittest.main(verbosity=2)
