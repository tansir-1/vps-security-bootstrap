# 项目维护约定

## 永久安装入口（用户明确要求）

所有修复、UI 优化、功能扩展和版本升级，都必须保留以下用户命令。

root 用户的永久命令：

```bash
curl -fsSL https://raw.githubusercontent.com/tansir-1/vps-security-bootstrap/main/install.sh | bash
```

普通 sudo 用户使用同一永久入口：

```bash
curl -fsSL https://raw.githubusercontent.com/tansir-1/vps-security-bootstrap/main/install.sh | sudo bash
```

- 保留仓库 `tansir-1/vps-security-bootstrap`、`main` 分支及根目录 `install.sh` 作为兼容入口。
- 升级时更新安装器内部的默认正式版本与固定 SHA256；推荐命令始终不含版本号，也不需要用户设置版本环境变量。
- 固定版本下载属于可选排障/复现方式，不可替代 README 中的永久推荐命令。
- 只有用户明确要求迁移入口时才修改此约定；日常修复、优化、升级不构成迁移授权。

## 修改与发布

涉及安装器、README 安装说明、版本或发布工作流时，先读取并遵循 [安装与发布契约](docs/INSTALLATION.md)。发布附件及哈希验证通过后，再把默认入口切换到新版本。

提交前运行 `python3 tests/entrypoint.py` 和 `python3 tests/static_safety.py`；修改 Bash 或交互时，同时完成 [测试文档](docs/TESTING.md) 中的相应检查。保持现有 SHA256 校验、Bash 语法验证和已发布附件不可覆盖的规则。

按用户约定直接快进更新 `main`，不创建工作分支或 PR，不强制推送。保留工作区已有改动，保持变更与本次用户请求相符。
