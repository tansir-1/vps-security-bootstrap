# VPS Security Bootstrap

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
curl -fLO https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/vps-security-bootstrap/main/vps-security.sh
bash -n vps-security.sh
less vps-security.sh
sudo bash vps-security.sh
```

将 `YOUR_GITHUB_USERNAME` 替换为你的 GitHub 用户名。

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

> 修改 SSH 时仍强烈建议保留 IDC/VNC/Serial Console 等救援入口。

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
