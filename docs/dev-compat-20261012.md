# dev 分支：Non-GKI 接口兼容与验证（2026-10-12）

`dev` 继承 `builtin` 的上游同步、Manager UAPI 5 和既有 Non-GKI 兼容层。实验变更不改管理器协议、不替换 5.10+ 的原生 SELinux hide，也不把上游 ReSukiSU 的整套策略解析重构直接覆盖旧内核代码。

| 内核系列 | 本次验证 | 边界 |
| --- | --- | --- |
| 4.9.337（Evolution-X `bka`） | 在真实源码头文件上验证 LSM、VFS、FD 接口探测；SUSFS 4.9 补丁中的 v2.3.0 核心头文件/API 通过预检 | 未进行完整编译或设备实测 |
| 4.14 | 使用旧式与回移植接口的模拟用例验证探测器 | 未取得目标设备源码编译 |
| 4.19.325（`114514_kernel_xiaomi_sdm845`） | Clang 12、`CONFIG_KSU=y`、不启用 SUSFS 的 `drivers/kernelsu/` 定向编译通过；SUSFS 4.19 补丁中的 v2.3.0 核心头文件/API 通过预检 | 通用 SUSFS 4.19 补丁在该厂商树上有 7 处冲突，未做 SUSFS 完整编译；需要机型修复补丁 |
| 5.4 | 模拟回移植接口用例通过 | 未取得目标设备源码编译 |

`kernel/scripts/probe-compat.sh` 基于实际声明选择 `setprocattr` 原型、LSM 链表与名称字段、`kernel_read/write` 参数和 `close_fd`，不依赖伪装后的 `uname`。`kernel/scripts/check-susfs-tree.sh` 在启用 SUSFS 时先检查核心文件、`SUSFS_VERSION` 和 KernelSU 使用的进程标志接口。测试命令：

```sh
bash .github/tests/test-non-gki-probes.sh
bash .github/tests/test-susfs-tree.sh
```

只要启用 SUSFS，仍需将相应系列的完整 SUSFS 补丁、机型冲突修复和 inline hook 正确应用到内核树。头文件通过预检只能说明关键声明存在，不代表挂载隐藏、SELinux 状态隐藏、SU 环境或功耗表现已在手机上验证。针对“无泄露”的结论必须结合设备端应用检测、`dmesg`/audit、挂载命名空间及 SUSFS 运行行为测试；不能从编译结果推断。
