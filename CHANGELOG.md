# Changelog

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
