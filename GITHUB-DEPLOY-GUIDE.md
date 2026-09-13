# GitHub 傻瓜式部署教程

## 1. 仓库命名

Repository name：

```text
vps-security-bootstrap
```

Description：

```text
Safe interactive Debian/Ubuntu VPS bootstrap & hardening tool with SSH rollback, firewall protection, business-port preflight, Docker/IPv6 audit and security reports.
```

Visibility：

```text
Public
```

License：

```text
MIT
```

## 2. 创建仓库

GitHub 右上角 `+` → `New repository`。

填写：

```text
Owner：你的 GitHub 用户名
Repository name：vps-security-bootstrap
Description：上面的 Description
Public：勾选
```

如果你准备直接上传本项目完整文件夹：

- `Add a README file`：不要勾也可以，因为包里已经有 README.md
- `.gitignore`：None
- License：可以不在网页重复创建，因为包里已经有 LICENSE

点击 `Create repository`。

## 3. 上传文件

仓库页面：

```text
Add file
→ Upload files
```

把本项目目录里的文件和文件夹上传，保持原目录结构：

```text
.github/
dist/
tests/
tools/
CHANGELOG.md
CONTRIBUTING.md
LICENSE
README.md
README_EN.md
SECURITY.md
VERSION
vps-security.sh
```

Commit message：

```text
Initial release: VPS Security Bootstrap v10.0.0
```

## 4. 设置 About

仓库右侧 `About` → 齿轮。

Description：

```text
Safe Debian/Ubuntu VPS bootstrap & security hardening tool.
```

Topics：

```text
vps
linux
security
hardening
bash
debian
ubuntu
ssh
ufw
fail2ban
server-security
docker
sysadmin
devops
```

## 5. 检查 Actions

打开：

```text
Actions
```

等待 CI。

必须看到绿色通过后再发布 Release。

## 6. 创建 v10.0.0 Release

仓库右侧：

```text
Releases
→ Create a new release
```

Tag：

```text
v10.0.0
```

Release title：

```text
VPS Security Bootstrap v10.0.0
```

建议 Release Notes：

```text
首个正式 GitHub 公开版本。

Highlights:
- 新 VPS / 已部署业务服务器通用安全开荒
- SSH 高位端口事务式修改与完整回滚
- ED25519 密钥登录
- UFW / firewalld 管理
- 已有 DENY 保护
- Fail2ban / 自动安全更新
- Docker 公网映射审计
- IPv6 防火墙审计
- 只读安全检查
- Copy-Paste SHA256 完整性验证
```

附件建议上传：

```text
vps-security.sh
dist/vps-security-copy-paste.txt
dist/SHA256SUMS
```

最后点击 `Publish release`。

## 7. README 中替换用户名

打开 `README.md`，找到：

```text
YOUR_GITHUB_USERNAME
```

替换为你的真实 GitHub 用户名。

例如用户名是 `example`：

```bash
curl -fLO https://raw.githubusercontent.com/example/vps-security-bootstrap/main/vps-security.sh
```

## 8. 后续版本命名

Bug 修复：

```text
v10.0.1
v10.0.2
```

新增功能：

```text
v10.1.0
```

大规模不兼容更新：

```text
v11.0.0
```
