# VPS Security Bootstrap

[简体中文](#简体中文) | [English](#english)

---

<a id="简体中文"></a>

## 简体中文

> 面向 Debian / Ubuntu 的交互式 VPS 新机开荒与已部署服务器安全加固工具。

核心原则：

**不锁 SSH、不误关业务端口、不静默覆盖已有 DENY、关键改动可验证/可回滚。**

当前版本：`v10.0.0`

## 快速开始

### 推荐：一键运行固定版本 v10.0.0

适合大多数用户，脚本会下载正式 Release、校验 SHA256、执行 Bash 语法检查，通过后才启动。

root 用户：

```bash
curl -fsSL https://raw.githubusercontent.com/tansir-1/vps-security-bootstrap/main/install.sh | bash
```

普通 sudo 用户：

```bash
curl -fsSL https://raw.githubusercontent.com/tansir-1/vps-security-bootstrap/main/install.sh | sudo bash
```

### 直接运行 Release 主脚本

```bash
curl -fsSL https://github.com/tansir-1/vps-security-bootstrap/releases/download/v10.0.0/vps-security-v10.0.0.sh -o /tmp/vps-security.sh && bash /tmp/vps-security.sh
```

### 下载源码后检查再运行

安全工具建议先检查源码：

```bash
curl -fLO https://raw.githubusercontent.com/tansir-1/vps-security-bootstrap/main/vps-security.sh
bash -n vps-security.sh
less vps-security.sh
sudo bash vps-security.sh
```

> 生产服务器建议优先使用固定 Release 版本，不要直接依赖持续变化的 `main` 分支。

## Netcatty / Xshell / FinalShell

如果你更喜欢“整段复制粘贴”：

打开仓库里的：

```text
dist/vps-security-copy-paste.txt
```

整段 `Ctrl+A → Ctrl+C`，粘贴到 SSH 终端执行。

Copy-Paste 版本会：

1. 解码主源码
2. SHA256 完整性校验
3. `bash -n` 语法检查
4. 全部通过后启动工具

## 适用场景

- 刚重装的全新 VPS
- 已运行 Docker / 1Panel / Nginx / OpenResty / x-ui / 3x-ui / Komari / QingLong 等业务的服务器
- 希望把 SSH、安全更新、防火墙、Fail2ban、Docker/IPv6 审计和安全报告集中在一个菜单中

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

`0` 只退出工具，不会主动关闭当前 SSH 会话。

## 主要功能

- 系统更新
- 检测已部署业务并使用更保守的更新模式
- 修改 root 密码
- SSH 随机高位端口
- ED25519 公钥登录
- 新窗口密钥登录验证
- 关闭 SSH 密码认证
- SSH 高风险变更事务式备份、验证与回滚
- ssh.service / ssh.socket 状态处理
- UFW / firewalld 自动识别
- 自定义 nftables 只读保护
- 已有 UFW DENY 冲突保护
- Fail2ban
- unattended-upgrades 自动安全更新
- 业务端口保护预检
- Docker 公网映射检查
- DOCKER-USER 检查
- IPv6 防火墙覆盖检查
- 只读安全审计（PASS / WARN / FAIL / INFO）
- SSH KeepAlive 可选连接稳定性优化
- 防火墙端口放行 / 关闭菜单
- 安全报告
- 配置备份
- 日志和历史清理

## 本工具不会默认做什么

本项目不会默认：

- 禁用 IPv6
- 禁止 Ping / ICMP
- 批量修改来源不明的 sysctl 参数
- `ufw reset`
- 清空已有防火墙规则
- 自动删除已有 DENY / reject 规则
- 自动覆盖自定义 nftables
- 默认改写 Docker `DOCKER-USER`
- 自动关闭未知公网业务端口

## SSH 安全设计

修改 SSH 端口前，会创建事务快照，包括：

- `sshd_config`
- `sshd_config.d`
- `authorized_keys`
- `ssh.service` / `ssh.socket` 状态
- UFW / firewalld 配置快照
- Fail2ban SSH 配置
- 工具状态文件

流程大致为：

```text
备份
→ 修改 SSH
→ 放行新端口
→ 校验 sshd 配置
→ 确认新端口监听
→ 新窗口登录测试
→ 成功后提交
```

如果失败，可恢复到修改前状态。

> 修改 SSH 或防火墙时，仍建议保留当前已登录 SSH 窗口，或 IDC / VNC / Web Console / Serial Console 等救援入口。

## 防火墙原则

如果已经存在：

```text
3306/tcp DENY
```

即使检测到 MySQL 正在监听，本工具也不会自动把 DENY 删除并改成 ALLOW。

冲突会显示给用户，由用户明确选择。

## Docker 说明

Docker 发布端口可能绕过普通 UFW `INPUT` 链。

v10.0.0 默认以**审计**为主：

- 查看公网映射
- 查看绑定地址
- 检查 `DOCKER-USER`
- 不擅自覆盖已有 Docker 防火墙规则

## IPv6

如果服务器存在公网 IPv6，本工具会检查主机防火墙是否覆盖 IPv6。

不会默认关闭 IPv6。

## 工具数据目录

运行后的数据主要保存在：

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

## 安全审计

只读安全检查不会修改系统配置。

主要检查：

- 系统版本
- SSH
- SSH 密钥
- 密码认证
- root 登录
- SSH 监听端口
- ssh.socket
- 防火墙
- IPv4 / IPv6
- Fail2ban
- 自动安全更新
- 公网监听
- Docker 映射
- DOCKER-USER
- 重启需求
- 时间同步等

结果使用：

```text
PASS
WARN
FAIL
INFO
```

## 支持范围

主要面向：

- Debian 11 / 12 / 13
- Ubuntu 20.04 / 22.04 / 24.04 / 26.04

不同 IDC 镜像可能存在定制 SSH、防火墙、cloud-init 或网络配置。首次在新环境使用时建议保留厂商控制台救援入口。

## 开发与构建

Bash 语法检查：

```bash
bash -n vps-security.sh
bash -n tools/build-copy-paste.sh
bash -n tests/smoke.sh
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

## 安全说明

不要在 Issue、截图、日志或聊天中公开：

- SSH 私钥
- SSH Passphrase
- root 密码
- API Token
- Cloudflare Token
- GitHub Token
- Telegram Token
- 其他服务器凭据

## Release

当前正式版本：

```text
v10.0.0
```

生产环境建议优先使用固定 Release，而不是直接运行 `main` 分支。

## License

MIT

---

<a id="english"></a>

## English

[Back to 简体中文](#简体中文)

> An interactive Debian/Ubuntu VPS bootstrap and hardening tool for both fresh servers and already-deployed production servers.

Core principles:

**Do not lock out SSH. Do not accidentally close business ports. Do not silently overwrite existing DENY rules. Make risky changes verifiable and recoverable.**

Current version: `v10.0.0`

## Quick Start

### Recommended: run the pinned v10.0.0 release

For root users:

```bash
curl -fsSL https://raw.githubusercontent.com/tansir-1/vps-security-bootstrap/main/install.sh | bash
```

For sudo users:

```bash
curl -fsSL https://raw.githubusercontent.com/tansir-1/vps-security-bootstrap/main/install.sh | sudo bash
```

The installer downloads the official Release asset, verifies the pinned SHA256, runs `bash -n`, and starts the tool only when all checks pass.

### Run the Release script directly

```bash
curl -fsSL https://github.com/tansir-1/vps-security-bootstrap/releases/download/v10.0.0/vps-security-v10.0.0.sh -o /tmp/vps-security.sh && bash /tmp/vps-security.sh
```

### Download, inspect, and run the source

```bash
curl -fLO https://raw.githubusercontent.com/tansir-1/vps-security-bootstrap/main/vps-security.sh
bash -n vps-security.sh
less vps-security.sh
sudo bash vps-security.sh
```

> For production servers, a pinned Release is recommended instead of relying directly on the changing `main` branch.

## Netcatty / Xshell / FinalShell

For a copy-paste workflow, open:

```text
dist/vps-security-copy-paste.txt
```

Copy the complete file and paste it into the SSH terminal.

The Copy-Paste build will:

1. Decode the main source
2. Verify SHA256
3. Run `bash -n`
4. Start the tool only after all checks pass

## Use Cases

- Freshly reinstalled VPS instances
- Servers already running Docker / 1Panel / Nginx / OpenResty / x-ui / 3x-ui / Komari / QingLong and other workloads
- Users who want SSH hardening, firewall management, Fail2ban, unattended security upgrades, Docker/IPv6 auditing, and reports in one menu-driven tool

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

## Main Features

- System updates
- Conservative update mode on servers with existing workloads
- Root password management
- Random high SSH port
- ED25519 public-key authentication
- Login verification from a new SSH session
- Disable SSH password authentication
- Transactional backup, verification, and rollback for SSH changes
- ssh.service / ssh.socket handling
- Automatic UFW / firewalld detection
- Read-only protection for custom nftables rules
- Existing UFW DENY conflict protection
- Fail2ban
- Automatic security updates with unattended-upgrades
- Business-port protection preflight
- Docker public-port audit
- DOCKER-USER audit
- IPv6 firewall coverage audit
- Read-only security audit with PASS / WARN / FAIL / INFO
- Optional SSH KeepAlive tuning
- Menu-driven firewall port allow / block
- Reports, backups, logs, and history cleanup

## What This Tool Does Not Do by Default

This project does **not** automatically:

- Disable IPv6
- Disable Ping / ICMP
- Apply large collections of unexplained sysctl tweaks
- Run `ufw reset`
- Clear existing firewall rules
- Delete existing DENY / reject rules
- Overwrite custom nftables rules
- Rewrite Docker `DOCKER-USER` by default
- Close unknown public business ports automatically

## SSH Safety Design

Before changing the SSH port, the tool creates a transaction snapshot including:

- `sshd_config`
- `sshd_config.d`
- `authorized_keys`
- `ssh.service` / `ssh.socket` state
- UFW / firewalld configuration snapshot
- Fail2ban SSH configuration
- Tool state files

Typical flow:

```text
backup
→ change SSH
→ allow new port
→ validate sshd configuration
→ confirm the new port is listening
→ verify from a new SSH session
→ commit
```

If verification fails, the previous state can be restored.

> Keep an existing SSH session or an IDC / VNC / Web Console / Serial Console recovery path available when changing SSH or firewall settings.

## Firewall Policy

If an existing rule is found:

```text
3306/tcp DENY
```

the tool will not silently remove the DENY rule and replace it with ALLOW, even if MySQL is listening on that port.

Conflicts require an explicit user decision.

## Docker Notes

Docker-published ports may bypass normal UFW `INPUT` handling.

v10.0.0 focuses on auditing:

- Public mappings
- Bind addresses
- `DOCKER-USER`
- Existing Docker firewall state

It does not silently overwrite existing Docker firewall rules.

## IPv6

If a public IPv6 address exists, the tool checks whether the host firewall covers IPv6.

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

## Read-Only Security Audit

The read-only audit does not modify system configuration.

Checks include:

- OS version
- SSH
- SSH keys
- Password authentication
- Root login
- SSH listening port
- ssh.socket
- Firewall
- IPv4 / IPv6
- Fail2ban
- Automatic security updates
- Public listeners
- Docker mappings
- DOCKER-USER
- Reboot requirements
- Time synchronization

Results use:

```text
PASS
WARN
FAIL
INFO
```

## Supported Systems

Primarily intended for:

- Debian 11 / 12 / 13
- Ubuntu 20.04 / 22.04 / 24.04 / 26.04

IDC images may contain customized SSH, firewall, cloud-init, or networking settings. Keep access to the provider recovery console when using the tool on a new environment for the first time.

## Development and Build

Syntax checks:

```bash
bash -n vps-security.sh
bash -n tools/build-copy-paste.sh
bash -n tests/smoke.sh
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

Every Push / Pull Request automatically runs:

- Bash syntax checks
- High-priority ShellCheck checks
- Smoke tests
- Copy-Paste distribution consistency checks

## Security Notice

Do not publish the following in Issues, screenshots, logs, or chats:

- SSH private keys
- SSH passphrases
- Root passwords
- API tokens
- Cloudflare tokens
- GitHub tokens
- Telegram tokens
- Other server credentials

## Release

Current stable release:

```text
v10.0.0
```

For production servers, use a pinned Release rather than the moving `main` branch.

## License

MIT
