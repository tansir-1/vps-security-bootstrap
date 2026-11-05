# 永久安装与升级入口

这是用户明确要求长期保留的公开接口。后续 AI 和维护者在修复、优化、重构或升级项目时，遵循根目录 [AGENTS.md](../AGENTS.md)。

## 用户始终使用的命令

root 用户：

```bash
curl -fsSL https://raw.githubusercontent.com/tansir-1/vps-security-bootstrap/main/install.sh | bash
```

普通 sudo 用户：

```bash
curl -fsSL https://raw.githubusercontent.com/tansir-1/vps-security-bootstrap/main/install.sh | sudo bash
```

同一个用户只需要保存对应权限的这一条命令。以后发布 10.1.3、10.2.0 或其他版本时，命令中的 URL 均不变化，也不增加版本参数。两条命令只有是否使用 sudo 的区别。

每次执行都会重新获取 `main/install.sh`。安装器读取内部维护的默认正式版本，下载对应 Release 附件，验证固定 SHA256 和 Bash 语法，通过后进入工具。现有 `VPS_SECURITY_VERSION` 保留作主动指定旧版本的高级选项；正常使用永久命令时无需设置它。

已经下载到服务器的旧 `.sh` 文件、旧版复制粘贴包，以及正在运行的进程不会自动更新。需要新版时先在菜单输入 `0` 退出，再执行永久命令。升级工具不代表需要重新执行安全加固步骤。

## 维护者每次升级负责的工作

1. 保留相同仓库、`main` 及根目录 `install.sh` 路径，保持 root 和 sudo 两种公开命令兼容。
2. 在源码和 `VERSION` 中更新版本；在安装器中加入新版本对应的固定 SHA256，保留旧版本固定哈希。重新构建 `dist/`，补齐发布说明。
3. 运行语法、ShellCheck、smoke、行为回归、UI、静态安全和 `tests/entrypoint.py` 检查。README 中英文的前两条推荐命令必须仍为以上永久命令。
4. 在已验证的提交上打新标签，先推送标签生成 Release。确认 CI/Release 成功、三个附件可下载，发布主脚本与本地验证源码一致，安装器内置哈希匹配，附件校验清单通过。
5. 附件就绪后，再把包含新默认版本和哈希的同一提交快进推送到 `main`。默认入口始终指向已可用的正式 Release。
6. 验证远端 `main/install.sh` 的默认版本和固定哈希已经同步，并检查默认分支 CI。保留原来的永久推荐命令，只更新版本介绍、变更记录和可选的固定版本下载示例。

用户已约定直接更新 `main`，无需创建分支或 PR。以上发布顺序可在本地提交后先推标签、后推 `HEAD:main` 完成，不需要临时工作分支。

已发布标签和附件保持不变；后续修复使用新版本。安装入口固定不表示绕过现有 SHA256 校验，也不表示在用户服务器上自动运行加固步骤。

## 自动检查与限制

`python3 tests/entrypoint.py` 检查入口文件、仓库标识、中英文首选安装命令，以及 AI 维护文档中的固定命令。CI 和 Release 工作流都运行它，意外改变入口会报错。`tests/static_safety.py` 继续检查默认版本与源码版本一致、主脚本固定哈希和发行包内容一致。

维护约定和 CI 用于防止无意变更；拥有仓库写权限的维护者仍应遵守用户要求，不能通过删除检查来规避入口兼容约定。
