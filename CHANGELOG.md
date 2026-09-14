# Changelog

## v10.1.0 - 2026-09

### Added / Changed
- 启动时识别 Debian、Ubuntu、RHEL、CentOS Stream、Rocky Linux、AlmaLinux、Oracle Linux、Fedora 和 Amazon Linux。
- 按发行版选择 apt、dnf 或 yum，并适配系统更新、依赖安装、主机防火墙、Fail2ban 和自动安全更新。
- RHEL/Fedora 系修改 SSH 端口时同步处理 SELinux `ssh_port_t`，并纳入 SSH 事务回滚。
- 通用安全开荒的预检和每个步骤都可选择执行、跳过或停止。
- 主菜单新增 IPv6 网络栈开启/关闭，包含配置备份、即时校验和失败回滚。

## v10.0.2 - 2026-09

### Fixed
- 修复 Debian 12 / Fail2ban 1.0.2 不支持 `fail2ban-client get sshd port`，导致安装 Fail2ban 和修改 SSH 端口被误判失败的问题。
- Fail2ban 端口同步现在通过完整配置检查、服务重启和 sshd jail 状态进行验证。
- 固定 Bash、测试和发行文件使用 LF 换行，避免 Windows Git 检出后破坏语法检查和 SHA256。

## v10.0.1 - 2026-09

### Security / Reliability
- 修正 UFW 已安装但未启用时对自定义 nftables 的识别优先级。
- 增加自定义 iptables INPUT 规则检测，并保持只读保护。
- firewalld 改为优先识别默认路由网卡实际所在的 active zone。
- install.sh 与 Copy-Paste 包改用随机 mktemp 临时文件并自动清理。
- Copy-Paste 包在独立子 Shell 中运行，校验失败不会退出当前 SSH 会话。
- SSH 切换成功后不再静默删除旧端口防火墙规则，改为显式询问。
- SSH 事务可恢复“原本不存在 authorized_keys”的状态。
- 修正 UFW 未启用时 IPv6 防火墙状态误报为已覆盖的问题。
- Fail2ban sshd jail 新增实际端口生效验证。

### CI / Release
- CI 纳入 install.sh 的 Bash/ShellCheck 检查。
- 新增静态安全不变量测试。
- actions/checkout 固定到 v7 对应 commit SHA。
- 新增自动 Release 工作流，VERSION 升级且验证通过后生成带 SHA256SUMS 的正式附件。

## v10.0.0 - 2026-09

### Added
- SSH 端口变更事务：配置、防火墙、Fail2ban、ssh.socket 可整体回滚。
- UFW / firewalld 后端识别和端口管理。
- 自定义 nftables 只读保护模式，避免覆盖现有规则。
- Docker 公网映射和 DOCKER-USER 只读审计。
- IPv6 地址与防火墙覆盖检查，可选修复 UFW IPv6 支持。
- 只读安全审计（PASS / WARN / FAIL / INFO）。
- SSH KeepAlive 可选稳定性设置。
- GitHub Actions、ShellCheck、Smoke Test。
- 可重复构建的 Copy-Paste 发行文件与真实 SHA256 校验。

### Changed
- 已有 UFW DENY 不再被脚本静默删除；冲突必须由用户明确处理。
- 检测到已部署业务时，系统更新默认使用更保守的 needrestart 模式。
- 单项任务失败后回到工具流程，不再因为普通命令失败直接退出 SSH 工具。
- 主菜单展示系统、IPv4/IPv6、Docker、防火墙和重启状态。

### Fixed
- SSH 端口回滚后 Fail2ban / ssh.socket / 防火墙状态不一致的问题。
- firewalld 存在时仍错误调用 UFW 的逻辑。
- 部分 systemd 检测在 pipefail 下被 SIGPIPE 误判的问题。
