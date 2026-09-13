# VPS Security Bootstrap

[简体中文](#简体中文) | [English](#english)

---

<a id="简体中文"></a>
## 简体中文

> 面向 Debian / Ubuntu 的交互式 VPS 新机开荒与已部署服务器安全加固工具。

核心原则：

**不锁 SSH、不误关业务端口、不静默覆盖已有 DENY、关键改动可验证/可回滚。**

当前版本：`v10.0.0`

## 适用场景

- 刚重装的全新 VPS
- 已运行 Docker / 1Panel / Nginx / OpenResty / x-ui / 3x-ui / Komari / QingLong 等业务的服务器
- 想把 SSH、主机防火墙、Fail2ban、自动安全更新和安全检查统一到一个菜单中

## 主要功能

- 系统更新，已部署业务机默认使用更保守的更新模式
- 修改 root 密码
- SSH 随机高位端口
- ED25519 公钥登录
- 新窗口密钥登录验证
- 关闭 SSH 密码认证
- SSH 端口变更完整事务：SSH 配置 / ssh.socket / 防火墙 / Fail2ban 可回滚
- UFW / firewalld 自动识别
- 自定义 nftables 只读保护，不擅自覆盖
- 已有 UFW DENY 冲突保护
- Fail2ban
- unattended-upgrades 自动安全更新
- 业务端口保护预检
- Docker 公网映射与 DOCKER-USER 检查
- IPv6 防火墙覆盖检查
- 只读安全审计（PASS / WARN / FAIL / INFO）
- SSH KeepAlive 可选连接稳定性优化
- 防火墙端口放行 / 关闭菜单
- 安全报告、备份、日志和历史清理
- 退出工具不会关闭当前 SSH 会话

## 本工具不会默认做什么

本项目不会默认：

- 禁用 IPv6
- 禁止 Ping / ICMP
- 批量修改来源不明的 sysctl 参数
- `ufw reset`
- 清空用户已有防火墙规则
- 自动删除已有 DENY / reject 规则
- 自动覆盖自定义 nftables
- 默认改写 DOCKER-USER
- 自动关闭未知公网业务端口

## 推荐运行方式

安全工具建议先下载并检查源码：

```bash
curl -fLO https://raw.githubusercontent.com/tansir-1/vps-security-bootstrap/main/vps-security.sh
bash -n vps-security.sh
less vps-security.sh
sudo bash vps-security.sh
```

### Netcatty / Xshell / FinalShell 复制粘贴方式

打开：

```text
dist/vps-security-copy-paste.txt
```

整段 `Ctrl+A → Ctrl+C`，粘贴到 SSH 终端运行。

Copy-Paste 版本会：

1. 解码主源码
2. 对主源码执行 SHA256 校验
3. 执行 `bash -n`
4. 全部通过后才启动工具

## 主菜单

```text
1. 通用安全开荒
2. 单项安全优化
3. 业务端口保护预检 / 重新扫描
4. 防火墙端口管理
5. 只读安全检查
6. Docker 安全检查
7. 高级设置
8. 重启服务器
0. 退出工具
```

`0` 只退出工具，不会主动关闭当前 SSH 连接。

## SSH 安全设计

修改 SSH 端口时会先创建事务快照，包括：

- `sshd_config`
- `sshd_config.d`
- `authorized_keys`
- `ssh.service` / `ssh.socket` 状态
- UFW / firewalld 配置快照
- Fail2ban SSH 配置
- 工具状态文件

新窗口测试失败时可整体回滚，避免留下“SSH 恢复了但 Fail2ban / 防火墙还指向新端口”的半配置状态。

> 修改 SSH 时仍强烈建议保留 IDC / VNC / Serial Console 等救援入口。

## 防火墙原则

如果发现已有：

```text
3306/tcp DENY
```

即使检测到 MySQL 正在监听，本工具也不会自动把 DENY 删除并改成 ALLOW。

冲突会显示给用户，由用户明确选择。

## Docker 说明

Docker 发布端口可能绕过普通 UFW `INPUT` 链。

v10.0.0 默认只审计 Docker 公网映射和 `DOCKER-USER`，不会擅自写入 Docker 防火墙规则，避免破坏现有业务。

## IPv6

如果服务器存在公网 IPv6，本工具会检查主机防火墙是否覆盖 IPv6。

不会默认关闭 IPv6。

## 文件目录

工具运行后主要数据位于：

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

## 开发与构建

语法检查：

```bash
bash -n vps-security.sh
bash -n tools/build-copy-paste.sh
```

Smoke Test：

```bash
bash tests/smoke.sh
```

重新生成 Copy-Paste 发行文件：

```bash
bash tools/build-copy-paste.sh
```

输出：

```text
dist/vps-security-copy-paste.txt
dist/SHA256SUMS
```

## GitHub Actions

每次 Push / Pull Request 自动执行：

- Bash 语法检查
- ShellCheck 高优先级错误检查
- Smoke Test
- Copy-Paste 发行文件一致性检查

## 支持范围

主要面向：

- Debian 11 / 12 / 13
- Ubuntu 20.04 / 22.04 / 24.04 / 26.04

不同 IDC 镜像可能存在定制 SSH、防火墙或 cloud-init 配置。首次在新环境使用前建议保留厂商控制台救援入口。

## 安全说明

不要在 Issue、截图或日志中公开：

- SSH 私钥
- SSH Passphrase
- root 密码
- API Token
- Cloudflare Token
- GitHub Token
- 其他服务器凭据

## License

MIT

---

<a id="english"></a>
## English

[返回简体中文](#简体中文)

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
