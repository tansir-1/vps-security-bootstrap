# v10.1.1 安全与可靠性检查

本次检查基于 2026-11-05 下载的上游 main 源码，修复记录整理于 2026-11-06。
这是源码审查与隔离执行结果，不是对生产环境无漏洞的保证。

## 已复现并修复

| 编号 | 严重性 | 触发条件与影响 | 修复位置 |
| --- | --- | --- | --- |
| 1 | 高 | 未确认的 SSH 端口事务被关闭密码或 KeepAlive 步骤覆盖，丢失原恢复入口 | `begin_ssh_transaction` 统一拒绝覆盖；所有调用者检查返回值 |
| 2 | 高 | 快照复制/归档失败仍继续修改 SSH，可能没有有效备份 | `begin_ssh_transaction` 对必要备份失败立即返回；UFW 恢复前检查归档 |
| 3 | 高 | 修改端口时因原密码已禁用而插入 `PermitRootLogin prohibit-password`，覆盖原有 `no` / `forced-commands-only` 策略 | `write_sshd_managed_block` 保留原 root 登录策略 |
| 4 | 高 | firewalld 先启动默认规则再放行自定义 SSH/业务端口，存在瞬间锁外风险 | 不再自动启动未运行的 firewalld；要求控制台离线预配置后启动 |
| 5 | 高 | UFW 写入失败、firewalld 拒绝冲突返回成功，调用者仍继续 SSH 切换或报告完成 | 显式传播失败；SSH 走统一 firewalld 检查；无法读取 rich rules 时停止 |
| 6 | 中 | UFW 忽略重叠范围、REJECT、未启用时的已保存简单拒绝规则，或将指定来源的 ALLOW 当作全局 ALLOW | `ufw_rule_state` 检查范围交集、DENY/REJECT 和来源 |
| 7 | 中 | firewalld 已有运行时放行就跳过永久规则；全量 reload 丢失其他运行时规则 | 同步两层规则；正常修改不 reload；SSH 回滚仅撤销本事务新增的放行 |
| 8 | 中 | `systemctl is-active/is-enabled` 已输出状态但返回非零，拼接 fallback 造成 `inactiveinactive` 等错误元数据 | 状态输出为空时才使用 fallback |
| 9 | 中 | `0080` 按八进制解析、超长数字发生算术溢出 | 先去前导零、限制长度，再按十进制校验 |
| 10 | 中 | 终端 EOF 被当作空输入，默认确认或菜单反复循环 | `ask` 读取失败以状态码 2 退出当前工具进程 |
| 11 | 中 | IPv6 失败后只恢复配置文件，内核状态未恢复；`sysctl --system` 连带应用其他配置 | 保存接口运行值；仅加载本工具文件；失败恢复原值 |
| 12 | 中 | 多实例覆盖事务和状态，写状态中断会留下半截文件 | `flock` 单实例锁；同目录临时文件原子替换状态 |
| 13 | 低 | `--audit` 要求 TTY，依赖不足可能提示安装，与只读用途不符 | 支持无终端输出；缺依赖直接失败，不安装软件 |
| 14 | 低 | Release 校验清单使用源码名，下载后的附件名无法直接校验；重复发布覆盖已固定哈希的附件 | 以实际附件名生成清单；上传不再使用 `--clobber` |

另外固定 root 工具的 PATH / C locale / umask，取消 `sudo -E` 的广泛环境继承；安装器和复制版收到信号时以非零码退出。

## 实际执行与边界

在 Windows 主机上使用官方 Git for Windows Bash 5.3.15 与 ShellCheck 0.11.0 执行：

- Bash 语法和 `--help` / `--version` smoke 测试。
- `tests/regression.py` 提取生产脚本中的函数，替换系统命令并在临时目录中执行。首批 12 项在原实现全部失败；修复并扩展后 19 项全部通过，覆盖 IPv6、状态原子写入等路径。
- 静态安全约束、安装器固定哈希、复制版解码一致性与构建可重复性检查。

没有在本机执行真实的 SSH、防火墙、账户、包管理器或内核设置变更，也没有完成 Debian/Ubuntu/RHEL 真机测试。systemd 服务重启、SELinux、真实规则顺序及云网络连通性仍需按 [TESTING.md](TESTING.md) 在可销毁 Linux VM 中验证。

## 仍需理解的限制

- SSH 新窗口登录是用户手动确认；没有独立定时自动回滚。断线后可能需要厂商控制台。不要将可回滚理解为一定不会锁外。
- UFW/firewalld 检查不是完整的规则解释器。来源、接口、应用 profile、direct rules、policy、Match/Include、自定义 sshd 启动参数及云安全组需人工复核。存在 firewalld rich 拒绝规则时采取保守停止策略，可能需要人工判断与目标端口是否相关。
- firewalld 回滚精确撤销新版本记录的新增 SSH 放行；旧版本事务缺少这些标记，不能据此承诺恢复运行时规则。配置归档仍保留作人工恢复参考。
- IPv6 运行值恢复不保证恢复已被内核移除的地址、路由或断开的连接；需网络服务/厂商重新配置。
- UFW 快照回滚会恢复整个 UFW 配置；不要同时人工修改防火墙。
- 修改 SSH 配置仍会统一管理主配置及标准目录中的 Port；复杂自定义 Include、多个监听端口与 Match 策略应先在控制台验证。

## 核对依据

- [systemctl 文档](https://www.freedesktop.org/software/systemd/man/latest/systemctl.html)：非 active/enabled 状态可能输出内容并返回非零。
- [OpenSSH sshd_config](https://man.openbsd.org/sshd_config)：root 登录策略及配置取值语义。
- [firewall-offline-cmd](https://firewalld.org/documentation/man-pages/firewall-offline-cmd.html)：离线预配置接口。

以上缺陷结论来自本仓库源码与测试；外部文档用于核对相关命令的语义。
