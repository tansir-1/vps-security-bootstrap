# Security Policy

## Supported version

当前维护：v10.x；当前版本 v10.1.2，发布附件见 GitHub Releases。

## Reporting a vulnerability

请优先使用 GitHub 仓库的 **Security → Report a vulnerability** / Private vulnerability reporting（如仓库已开启）提交安全问题。

请不要在公开 Issue 中粘贴以下内容：

- SSH 私钥或 Passphrase
- root 密码
- API Token / Cloudflare Token / GitHub Token
- 真实服务器凭据
- 含敏感信息的完整防火墙或配置备份

提交问题时建议提供：系统版本、脚本版本、错误步骤、脱敏后的日志和可复现步骤。

## 安全边界

[安全检查记录](docs/SECURITY-REVIEW.md) 记录已修复问题、测试范围及仍需人工验证的规则。没有定时自动 SSH 回滚；修改前保留独立控制台。SHA256 校验不等同于独立的发布签名。审计只读指不修改系统配置，仍会写工具自身数据。
