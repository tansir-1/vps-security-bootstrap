# GitHub 更新与发布

当前版本为 **10.1.2**。以下以该版本为例。本地修改不会自动更新 GitHub 或线上 Release；应先验证发布附件可用，再更新默认分支的安装入口。

## 发布前

1. 在具有真实上游历史的克隆中创建修复分支，检查完整 diff。不要将下载 ZIP 后的本地基线提交强推到 main。
2. 按 [测试文档](docs/TESTING.md) 完成自动检查与 Linux VM 验收。mock 测试不能替代真实 SSH/防火墙验证。
3. 确认 VERSION、主脚本、安装器默认版本、README 和 release-notes/v10.1.2.md 一致。
4. 修改主脚本后运行 `sha256sum vps-security.sh`，更新 install.sh 中对应版本的固定哈希。不要修改已发布旧版本的哈希。
5. 运行 `bash tools/build-copy-paste.sh`，提交主脚本、安装器、dist、测试、工作流和文档。英文内容包含在 README 中，没有独立 README_EN.md。
6. 提交 PR 并等待 CI 通过，合并后确认发布的是经过验证的提交。

## 创建版本

在验证过的上游提交上执行：

```bash
git tag -a v10.1.2 -m "VPS Security Bootstrap v10.1.2"
git push origin v10.1.2
```

标签触发 Release 工作流：检查版本、语法、ShellCheck、smoke、行为回归、静态约束及发行文件一致性，再准备附件：

```text
vps-security-v10.1.2.sh
vps-security-v10.1.2-copy-paste.txt
SHA256SUMS
```

Release 的 SHA256SUMS 使用实际附件名；仓库 dist/SHA256SUMS 使用源码相对路径，两者用途不同。

不要覆盖已发布附件或移动标签。上传不再使用 `--clobber`；同名附件存在会导致上传失败。修复应升级补丁版本，而非替换用户已经固定哈希的内容。

## 发布后验收

在新的私有临时目录中下载三个附件，运行 `sha256sum -c SHA256SUMS`，检查 `--version`。在可销毁 VM 中验证固定标签的 install.sh。附件确实可下载后，再将 README 与发布说明中的待发布状态更新为正式发布。

安装器验证内置哈希，但首次执行安装器时仍需信任其源码及标签；哈希校验不等同于独立数字签名。
