# 测试与真机验收

## 可自动运行的检查

需要 Bash 4+、Python 3、GNU coreutils/gzip 和 ShellCheck。不要以 root 身份运行回归测试。

```bash
bash -n vps-security.sh
bash -n install.sh
bash -n tools/build-copy-paste.sh
shellcheck -x -S warning vps-security.sh install.sh tools/build-copy-paste.sh tests/smoke.sh
bash tests/smoke.sh
python3 tests/regression.py
python3 tests/ui.py
python3 tests/intrusion.py
python3 tests/static_safety.py
python3 tests/entrypoint.py
bash tools/build-copy-paste.sh
git diff --exit-code -- dist/
git diff --check
```

首次修改源码后，先重新构建发行文件、更新 `install.sh` 中相应版本的固定 SHA256，再运行静态检查。`BASH_BIN` 可为 Python 回归测试指定 Bash 路径。

回归测试运行真实函数，以 mock 替换系统命令，并在临时目录中验证失败传播、规则处理和状态恢复；它不能替代 Linux 集成测试。

## Linux VM 验收清单（本次尚未执行）

使用可销毁且有独立控制台的 VM。建议至少覆盖 Debian 12/13、Ubuntu 24.04/26.04、Rocky/AlmaLinux 9/10；可识别发行版不代表这些镜像均已实测。

1. 保存 VM 快照；从第二终端建立连接；记录 `sshd -T`、监听端口和防火墙的运行/永久规则。
2. 测试 `ssh.service` 和 `ssh.socket` 两种启动模式；修改端口并分别提交/回滚，确认重启后可连接。
3. 端口事务未完成时尝试禁密码和 KeepAlive，必须拒绝覆盖；从菜单第 5 项完成或回滚后才能继续。
4. 分别模拟备份磁盘满、配置写失败、`sshd -t` 失败、服务重启失败和 Fail2ban 校验失败，确认停止并保留恢复入口。
5. UFW 测试 active/inactive、来源受限 ALLOW、范围 DENY、REJECT、复杂规则；确认 SSH 放行先于默认拒绝策略。
6. firewalld 测试运行时/永久规则各自存在或缺失、rich-rule 拒绝、非默认接口 zone。插入一条仅运行时的业务放行，操作及回滚后必须仍存在。
7. 无防火墙的 RPM VM 中确认工具不会直接启动 firewalld。通过控制台离线配置正确的 zone/接口、SSH 及业务放行后再启动。
8. SELinux enforcing 模式下验证新 SSH 端口登记、监听与回滚。
9. IPv6 各接口初值不同、无托管文件和已有文件三种情况，注入 sysctl 失败，确认文件及运行值恢复；另检查地址/路由。
10. `sudo bash vps-security.sh --audit </dev/null` 应输出报告且不装包、不修改系统配置；缺依赖应非零退出。审计会在工具数据目录写报告、日志和状态。
11. 启动两个工具实例，第二个应立即拒绝；交互输入断开应退出，不能执行默认确认。
12. 验证 Docker 公网映射/IPv6 暴露，并从外部机器实际测试允许和拒绝端口。云安全组需独立验证。

失败时保留脱敏日志及事务目录；不要公开含凭据的配置或备份。不要将 root 权限的完整交互流程直接运行在工作站上。
