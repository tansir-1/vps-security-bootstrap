# Contributing

感谢贡献。提交 PR 前请：

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
python3 tests/static_safety.py
bash tools/build-copy-paste.sh
```

如安装了 ShellCheck：

```bash
shellcheck -x -S error vps-security.sh install.sh tools/build-copy-paste.sh tests/smoke.sh
```
