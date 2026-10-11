# 2026-10-12 上游同步记录

本次以 SukiSU Ultra `builtin` 的 `6c284e957feaa9a388a9f1c37dc4ec80d95e434b` 为基线，通过 Git 合并保留了本仓库既有的 Non-GKI 层、管理器兼容和构建工作流。兼容补丁只针对 `kernel/`，与上游基线的差异由 `.github/scripts/generate-upstream-compat-patch.sh` 生成。

## 核对的 SukiSU Ultra 提交

| 提交 | 相关变化 | 本仓库处理 |
| --- | --- | --- |
| `64b863e` | app-profile 下的 FD wrapper | 合并，并保留既有受限 SELinux 域兼容 |
| `ea46e5e` | 扫描管理器 APK 时不触碰 fsnotify/atime | 合并 |
| `0ff39b1`、`1a29bcb` | avtab 迭代、xperms 和长度修复 | 合并；Non-GKI 副本另行对齐可安全复用的部分 |
| `e76786c` | RCU 保护下读取 SELinux policy | 合并；Non-GKI policy 更新入口同步修复 |
| `e038c7e` | 服务阶段去重 | 合并；配合 UAPI 5 的首次执行/跳过返回值 |
| `70fa0e0` | 同步 KernelSU 主线 | 合并，检查与自有兼容层的冲突 |
| `6c284e9` | 补充 `arch.h`，修复 builtin 构建 | 合并 |

官方 Manager `main` 的 `7ef2dbb` 引入 UAPI 5：`EVENT_SERVICES` 首次返回 1，重复返回 0，`post-fs-data` 复位。本仓库已核对事件处理代码、提升 UAPI 声明，并扩展自检脚本；不是单纯增加版本号。

## 核对的 ReSukiSU 隐藏提交

| 提交 | 内容 | 兼容版处理 |
| --- | --- | --- |
| `ba8cfa5` | 查询时同步实际 SID 表 | 为 Non-GKI 的 `/context`、`/access` 路径加入实际 SID 同步 |
| `969de3d` | 保持原始 `setprocattr` 权限检查顺序 | 仅当备份策略解析失败时先执行原权限检查 |
| `fa12ffd` | 双策略解析和时间侧信道修复，大幅重构旧内核兼容层 | 已审查；不把其整文件直接覆盖到独立 Non-GKI 实现，仍需版本/厂商内核验证 |

ReSukiSU 当前 `main` 还临时暂停了自己的 SUSFS 构建（`48fa4bb`）。因此本仓库没有复制其阻止构建的规则；SUSFS 2.3 的实验性适配在 `dev` 分支单独推进，不把未经验证的接口假设带入 `builtin`。

## 验证边界

Manager UAPI、SELinux 配置自检已通过。在独立的 4.19.325 测试树（`xiziya/114514_kernel_xiaomi_sdm845`）中，以 Clang 12、`CONFIG_KSU=y`、不启用 SUSFS 定向编译 `drivers/kernelsu/` 已通过。该测试发现并修复了上游 sulog 传入空 `user_arg_ptr` 时指针/值类型不一致的问题；两种构建路径现在各使用匹配的参数类型。

这不是完整内核构建，也未测试 SUSFS 2.3 的集成或设备端行为。编译通过不等于隐藏效果、功耗或所有厂商 4.9/4.19 分支均已实测。
