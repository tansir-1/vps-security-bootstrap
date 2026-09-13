# VPS Security Bootstrap

[简体中文](./README.md) | [English](./README_EN.md)

> An interactive Debian/Ubuntu VPS bootstrap and hardening tool for both fresh servers and already-deployed production servers.

Core principles:

**Do not lock out SSH. Do not accidentally close business ports. Do not silently overwrite existing DENY rules. Make risky changes verifiable and recoverable.**

Current version: `v10.0.0`

## Use Cases

- Freshly reinstalled VPS instances
- Servers already running Docker / 1Panel / Nginx / OpenResty / x-ui / 3x-ui / Komari / QingLong and other workloads
- Users who want SSH hardening, host firewall management, Fail2ban, unattended security upgrades, and security checks in one menu-driven tool

## Main Features

- System updates with a more conservative update mode for servers that already host workloads
- Root password change
- Random high SSH port
- ED25519 public-key login
- Login verification from a new SSH session
- Disable SSH password authentication
- Transactional SSH port changes with rollback for SSH config / ssh.socket / firewall / Fail2ban
- Automatic UFW / firewalld detection
- Read-only protection for custom nftables rules
- Protection against silently overriding existing UFW DENY rules
- Fail2ban
- Automatic security updates with unattended-upgrades
- Business-port protection preflight
- Docker public-port and DOCKER-USER audit
- IPv6 firewall coverage audit
- Read-only security audit with PASS / WARN / FAIL / INFO results
- Optional SSH KeepAlive connection-stability tuning
- Menu-driven firewall port allow / block management
- Security reports, backups, logs, and history cleanup
- Exiting the tool does not close the current SSH session

## What This Tool Does Not Do by Default

This project does **not** automatically:

- Disable IPv6
- Disable Ping / ICMP
- Apply large collections of unexplained sysctl tweaks
- Run `ufw reset`
- Clear existing firewall rules
- Delete existing DENY / reject rules
- Overwrite custom nftables rules
- Rewrite DOCKER-USER by default
- Close unknown public business ports automatically

## Recommended Usage

For a security tool, downloading and reviewing the source before execution is recommended:

```bash
curl -fLO https://raw.githubusercontent.com/tansir-1/vps-security-bootstrap/main/vps-security.sh
bash -n vps-security.sh
less vps-security.sh
sudo bash vps-security.sh
```

### Netcatty / Xshell / FinalShell Copy-Paste Method

Open:

```text
dist/vps-security-copy-paste.txt
```

Use `Ctrl+A → Ctrl+C`, then paste the entire content into the SSH terminal.

The Copy-Paste build will:

1. Decode the main source
2. Verify the source with SHA256
3. Run `bash -n`
4. Start the tool only if every check passes

## Main Menu

```text
1. General security bootstrap
2. Individual security optimization
3. Business-port protection preflight / rescan
4. Firewall port management
5. Read-only security audit
6. Docker security audit
7. Advanced settings
8. Reboot server
0. Exit tool
```

Option `0` exits only the tool and does not intentionally close the current SSH session.

## SSH Safety Design

Before changing the SSH port, the tool creates a transaction snapshot including:

- `sshd_config`
- `sshd_config.d`
- `authorized_keys`
- `ssh.service` / `ssh.socket` state
- UFW / firewalld configuration snapshot
- Fail2ban SSH configuration
- Tool state files

If verification from a new SSH session fails, the transaction can be rolled back as a whole, preventing half-restored states such as SSH returning to the original port while Fail2ban or the firewall still points to the new one.

> When changing SSH settings, keeping access to an IDC / VNC / Serial Console recovery path is still strongly recommended.

## Firewall Policy

If an existing rule is found:

```text
3306/tcp DENY
```

the tool will not silently remove the DENY rule and replace it with ALLOW, even if MySQL is detected as listening on that port.

Conflicts are shown to the user and require an explicit decision.

## Docker Notes

Docker-published ports may bypass normal UFW `INPUT` handling.

In v10.0.0, Docker public mappings and `DOCKER-USER` are audited by default. The tool does not automatically rewrite Docker firewall rules, reducing the risk of breaking existing services.

## IPv6

If the server has a public IPv6 address, the tool checks whether the host firewall also covers IPv6.

IPv6 is not disabled by default.

## Data Directory

Runtime data is mainly stored under:

```text
/root/vps-security/
├── backups/
├── logs/
├── preflight/
├── reports/
├── transactions/
├── protected-ports.tsv
├── server-info.txt
└── state.env
```

## Development and Build

Syntax checks:

```bash
bash -n vps-security.sh
bash -n tools/build-copy-paste.sh
```

Smoke test:

```bash
bash tests/smoke.sh
```

Rebuild the Copy-Paste distribution:

```bash
bash tools/build-copy-paste.sh
```

Outputs:

```text
dist/vps-security-copy-paste.txt
dist/SHA256SUMS
```

## GitHub Actions

Every push and pull request automatically runs:

- Bash syntax checks
- High-priority ShellCheck checks
- Smoke tests
- Copy-Paste distribution consistency checks

## Supported Systems

Primarily intended for:

- Debian 11 / 12 / 13
- Ubuntu 20.04 / 22.04 / 24.04 / 26.04

IDC images may contain customized SSH, firewall, or cloud-init settings. Keep access to the provider recovery console when using the tool on a new environment for the first time.

## Security Notice

Do not publish the following in Issues, screenshots, or logs:

- SSH private keys
- SSH passphrases
- Root passwords
- API tokens
- Cloudflare tokens
- GitHub tokens
- Other server credentials

## License

MIT
