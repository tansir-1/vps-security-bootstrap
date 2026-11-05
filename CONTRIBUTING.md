# Contributing

感谢贡献。修改前先阅读 [AGENTS.md](AGENTS.md)；安装、升级或发布相关改动还须遵循 [永久入口契约](docs/INSTALLATION.md)。按用户约定检查通过后直接更新 main，不新建分支或 PR。

1. 不在源码中写入真实 IP、密码、私钥、Token 或个人域名。
2. 保持脚本兼容 Debian/Ubuntu（apt）与 RHEL/Fedora 系（dnf/yum）的 systemd 环境。
3. 任何 SSH / 防火墙高风险修改必须先备份、再验证、失败可回滚。
4. 不默认关闭 IPv6、Ping，不批量写入来源不明的 sysctl 参数。
5. 不自动清空用户已有防火墙规则。
6. 运行：

```bash
bash -n vps-security.sh
bash -n install.sh
bash -n tools/build-copy-paste.sh
bash tests/smoke.sh
python3 tests/regression.py
python3 tests/ui.py
python3 tests/intrusion.py
python3 tests/static_safety.py
python3 tests/entrypoint.py
bash tools/build-copy-paste.sh
```

如安装了 ShellCheck：

```bash
shellcheck -x -S warning vps-security.sh install.sh tools/build-copy-paste.sh tests/smoke.sh
```

行为测试与真机测试的边界见 [docs/TESTING.md](docs/TESTING.md)。修改主脚本后须同步安装器对应版本的固定哈希，并重新生成 dist；发布附件不可覆盖原版本。
