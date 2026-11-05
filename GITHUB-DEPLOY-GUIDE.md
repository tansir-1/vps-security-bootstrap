# GitHub 更新与发布

修改前阅读 [AGENTS.md](AGENTS.md)。安装和发布相关改动遵循 [永久入口契约](docs/INSTALLATION.md)：用户始终使用同一个 `main/install.sh` 命令；维护者更新内部版本与固定哈希。下列是维护者操作，不是需要用户保存的运行命令。

## 发布前

1. 在具有真实上游历史的克隆中检查完整 diff。按用户约定直接快进更新 main，不创建分支或 PR，不强制推送本地 ZIP 基线。
2. 按 [测试文档](docs/TESTING.md) 完成自动检查与 Linux VM 验收。mock 测试不能替代真实 SSH/防火墙验证。
3. 确认 VERSION、主脚本、安装器默认版本和对应 release-notes 文件一致。README 的永久推荐命令保持不变。
4. 修改主脚本后运行 `sha256sum vps-security.sh`，更新 install.sh 中对应版本的固定哈希。不要修改已发布旧版本的哈希。
5. 运行 `bash tools/build-copy-paste.sh`，提交主脚本、安装器、dist、测试、工作流和文档。英文内容包含在 README 中，没有独立 README_EN.md。
6. 完成本地检查后创建待发布提交；先推标签并验证 Release，附件就绪后再更新 main 的默认入口。普通文档维护按用户约定直接更新 main 并检查 CI。

## 创建版本

在验证过的上游提交上执行：

```bash
VERSION="$(tr -d '[:space:]' < VERSION)"
git tag -a "v${VERSION}" -m "VPS Security Bootstrap v${VERSION}"
git push origin "refs/tags/v${VERSION}"
```

标签触发 Release 工作流：检查版本、语法、ShellCheck、smoke、行为回归、静态约束及发行文件一致性，再准备附件：

```text
vps-security-v<VERSION>.sh
vps-security-v<VERSION>-copy-paste.txt
SHA256SUMS
```

Release 的 SHA256SUMS 使用实际附件名；仓库 dist/SHA256SUMS 使用源码相对路径，两者用途不同。

不要覆盖已发布附件或移动标签。上传不再使用 `--clobber`；同名附件存在会导致上传失败。修复应升级补丁版本，而非替换用户已经固定哈希的内容。

## 发布后验收

在新的私有临时目录中下载三个附件，运行 `sha256sum -c SHA256SUMS`，检查 `--version` 以及安装器中的版本/哈希。在可销毁 VM 中验证固定标签的 install.sh。确认附件可用后，运行 `git push origin HEAD:main`，检查默认分支 CI 和远端安装器。

版本介绍及发布状态按实际结果更新，root 和 sudo 两条永久推荐命令保持原样。`python3 tests/entrypoint.py` 在 CI/Release 中检查这项兼容约定。

安装器验证内置哈希，但首次执行安装器时仍需信任其源码及标签；哈希校验不等同于独立数字签名。
