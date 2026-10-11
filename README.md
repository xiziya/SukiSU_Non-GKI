# SukiSU Non-GKI

这是基于 SukiSU Ultra `builtin` 分支的增量兼容移植，目标是在旧版 Non-GKI 内核中保留 SukiSU Ultra 的工作流，并补齐 SELinux hide 所需的接口和运行时 hook。

> 这是非官方移植。5.10 及以上内核继续使用 SukiSU Ultra 原有实现；新增兼容代码只在 `< 5.10` 时编译。

## 基线

- SukiSU Ultra `builtin`: `6c284e957feaa9a388a9f1c37dc4ec80d95e434b`（2026-10-09）
- ReSukiSU `main` 对照：`f6cb7e70c10ebde149f3121ae68b945514fd0801`（2026-10-11）
- 验证内核: Evolution-X-Devices `kernel_xiaomi_sdm845` `bka`
- 验证内核提交: `b0fb2a6d2d20c1f3219183e8590fff50a3a39fd6` (`4.9.337`)

## 移植范围

- `< 5.10` 单独编译 `kernel/non_gki/`，包含 SELinux hide、policydb/sidtab 备份、符号解析和 arm64 文本修补。
- 根据内核源码能力探测 SELinux/LSM 数据结构，不仅依赖版本号判断厂商回移。
- 修复 4.9 缺失的 `fallthrough`、`current_sid()`、`strncpy_from_user_nofault()` 和 kernel umount feature setter。
- 保持 SukiSU Ultra 5.10+ SELinux hide 实现和现有 SUSFS inline hook 路径不变。
- 如果 SUSFS 已提供新版 SELinux hide hook，则直接复用；否则使用 ReSukiSU 风格的运行时 function/LSM slot patch。
- `kernel/Makefile` 保留官方 builtin 的版本/UAPI 契约；GitHub API 或 `main` 引用不可用时使用本地提交计数或 `VERSION_BASE`，避免错误回退到管理器拒绝的 `KSU_VERSION=13000`。
- 兼容旧版 Manager 的 app-profile v2/v3 ioctl：按用户空间版本读写 776 字节前缀，并迁移到当前 v4 profile。
- 保留 Manager UAPI 3 的受限 SU 会话 FD 和 UAPI 4 的 bundled-LKM 能力位；SUSFS 手动 exec hook 只在 `su -> ksud` 成功后安装会话 FD，避免失败路径泄漏权限。
- `post-fs-data` 在 observer 注册后增加一次性 manager UID 扫描，覆盖 `packages.list` 已存在的旧版 Android 启动时序。
- Non-GKI 的每条 SELinux policy 更新路径都会刷新 SUSFS SID 缓存；原补丁的 `kernel/selinux/rules.c` hunk 不会覆盖实际编译的 `kernel/non_gki/rules.c`，已按实际入口移植。
- 同步上游的 SELinux RCU 受保护读取、xperms 合并和服务阶段去重逻辑；Non-GKI 独立实现中的对应路径也单独更新，不只合并 5.10+ 的文件。
- 参照 ReSukiSU `ba8cfa5`、`969de3d`，Non-GKI SELinux hide 的查询会同步实际 SID 表，`setprocattr` 的权限检查顺序与原始 hook 一致。`fa12ffd` 的全量双策略解析属于大幅结构改写，尚未直接覆盖本仓库的旧内核实现；不能仅凭编译通过声称完全消除时间侧信道。
- 对齐官方 Manager UAPI 5：`EVENT_SERVICES` 返回 1 表示首次执行、0 表示跳过重复服务阶段，并在 `post-fs-data` 时复位。保留先前 UAPI 3/4 的会话 FD 与 bundled-LKM 行为。

这些兼容修改已经直接合并在本仓库源码中。GitHub Actions 会从当前 checkout 直接运行 `kernel/setup.sh`，不再额外应用 Manager 兼容补丁，避免重复修改或上下文冲突。

## 集成到内核源码树

在内核源码根目录运行：

```sh
curl -LSs https://raw.githubusercontent.com/xiziya/SukiSU_Non-GKI/builtin/kernel/setup.sh | sh
```

脚本会自动识别 `drivers/` 或 `common/drivers/`，克隆 `builtin` 分支，创建 `drivers/kernelsu` 软链接，并幂等更新驱动 Makefile/Kconfig。也可以指定提交或标签：

```sh
curl -LSs https://raw.githubusercontent.com/xiziya/SukiSU_Non-GKI/builtin/kernel/setup.sh | sh -s -- <commit-or-tag>
```

清理脚本所做的集成：

```sh
curl -LSs https://raw.githubusercontent.com/xiziya/SukiSU_Non-GKI/builtin/kernel/setup.sh | sh -s -- --cleanup
```

本地调试可以通过 `KSU_REPO`、`KSU_BRANCH`、`KSU_DIR` 覆盖默认来源。

## 4.9 + SUSFS 手动 hook 顺序

1. 在纯净内核树应用对应版本的 SUSFS patch。
2. 运行本仓库 `kernel/setup.sh`，使 `drivers/kernelsu` 可见。
3. 从内核根目录运行 SUSFS inline hook 脚本。
4. 启用 `CONFIG_KSU=y` 与所需的 `CONFIG_KSU_SUSFS*` 配置后正常编译。

旧版 `susfs_inline_hook_patches.sh` 会搜索 `ksu_hide_setprocattr`。本移植不伪造该旧接口，因此脚本会跳过那一个 hook；SELinux hide 由 Non-GKI 运行时兼容层接管。脚本中的其他 SukiSU/SUSFS inline hooks 不受影响。

### 上游同步与分支

`builtin` 是稳定兼容版；上游基线为上述 SukiSU Ultra `builtin` 提交。`dev` 从该基线派生，单独放置旧内核接口探测、SUSFS 2.3 适配以及 SU/SELinux 隐藏的实验优化。`dev` 的功能不自动回灌到 `builtin`，须经过对应内核编译和设备实测。同步记录见 `docs/upstream-sync-20261012.md`。

### Zygisk Next 兼容性说明

Zygisk Next 是用户空间模块，不由 KernelSU 内核驱动实现。上游识别依赖 `GET_INFO` 返回的 `KSU_VERSION`、UAPI 版本和功能位；本仓库保留了 SukiSU Ultra 的 UAPI 编号，并在离线/浅克隆时使用稳定的非零版本回退，避免管理器把内核误判为旧版或不支持。内核本身没有可安全添加的“Zygisk 已启用”位，因此“需要重启”提示不能通过伪造一个内核功能位解决；安装/升级 Zygisk Next 后按其模块说明重启一次是正常行为。若重启后仍显示该提示，应提供 Zygisk Next bugreport 及管理器版本，不能仅凭内核编译日志判断。

## GitHub Actions 通用构建

`.github/workflows/build-custom-kernel-Zh_CN.yml` 提供简体中文 `workflow_dispatch` 构建入口，`.github/workflows/build-custom-kernel-Eng.yml` 提供英文入口。两者使用完全相同的构建逻辑和输入参数，仅界面显示语言不同。必须填写设备 `codename` 和以 `.git` 结尾的纯净内核仓库；`kernel_branch` 默认 `bka`。`defconfig` 请输入目录下的 `*_defconfig` 路径，例如 `vendor/xiaomi/mi845_defconfig`，也可以留空让工作流按 codename 自动探测；只有唯一候选才会自动使用，多个候选会直接失败并列出候选。`device_config` 是可选的 `目录/*.config` 路径。

工作流提供可选的内核版本伪装开关。启用后必须填写 `主版本.次版本.子版本` 三段纯数字版本号，例如 `4.9.337`。伪装在集成步骤之后登记，并在构建配置阶段只覆盖最终 `KERNELRELEASE`；不会重写内核根 `Makefile` 的 `VERSION`、`PATCHLEVEL`、`SUBLEVEL`，因此编译期 API 分支与 SUSFS 补丁仍按源码真实系列选择。跨系列伪装仅改变对外报告的版本字符串，不能为旧内核提供新版 API。

其余输入覆盖作者、A/B 分区、LTO、SUSFS + SukiSU 兼容版、内核名（空值为 `by_XiZi`）、构建时间、内核版本、DroidSpaces 和 AnyKernel3。可选的“固定 SELinux 为 Enforcing”默认关闭；启用后会保留 `CONFIG_SECURITY_SELINUX=y` 并禁用构建输出 `.config` 中的 `CONFIG_SECURITY_SELINUX_DEVELOP`，随后验证 Kconfig 没有覆盖该结果。工作流还会限定在 `sel_write_enforce()` 函数内识别 `new_value = 0` 这类源码级强制宽容修改，并恢复内核标准的 `new_value = !!new_value`；已是标准实现时不会改源码，无法识别时会停止构建而非盲目替换。这样既修复默认 permissive，也修复 `setenforce 1` 无效，并且不依赖 boot cmdline 的 `enforcing=1`。但 ROM sepolicy 不兼容时可能无法启动，因此不能替代依据 AVC 日志进行的精确 `.te` 策略修复。开关请求值、配置状态和源码修复状态都会写入构建报告。A/B 选项保留在报告中，但 AK3 刷入脚本会在设备端自动识别当前活动槽位，避免选项与实际设备状态不一致导致刷错 boot。主编译目标可选择 `Image.gz` 或 `Image.gz-dtb`；启用 AnyKernel3 时还可以独立选择打包目标，若目标不同于主编译目标，工作流会自动额外编译它。构建阶段会捕获存在的 `Image.gz`/`Image.gz-dtb` 并随产物上传，报告中记录捕获列表和 SHA-256 校验。对于同时包含 Qualcomm `qcacld-3.0`、`qca-wifi-host-cmn` 和 `fw-api` 的源码，工作流会强制保留 `CONFIG_QCA_CLD_WLAN=y`，将 WLAN 驱动直接链接进内核；AK3 不再携带或安装 `wlan.ko`。没有该完整布局的 MTK 或其他内核不会受到影响。构建身份会写入 `KBUILD_BUILD_USER`，自定义时间写入 `KBUILD_BUILD_TIMESTAMP`，内核 localversion 延续 `build.sh` 的 `-名称-版本-日期` 规则。启用 DroidSpaces 时，工作流会额外强制写入官方 Non-GKI 要求的 `CONFIG_USER_NS=y`，避免旧版配置片段遗漏该选项。构建报告会同时记录源码真实版本、版本伪装目标和伪装执行状态。

对于没有现代 VFS/backport 的碎片化 Non-GKI 内核，可以启用“机型专属补丁”。工作流会 clone 指定的 `.git` 仓库和分支，从其 `Patches/` 目录按空格分隔的文件名逐个分类。普通兼容补丁在通用 SUSFS 之前应用；新增行中包含 `CONFIG_KSU_SUSFS` 或 `susfs_` 的 SUSFS 修复补丁会自动暂存，在通用补丁出现冲突后再应用。关闭开关时这些仓库和文件输入不会被读取。

机型补丁可以直接包含针对该内核手工完成的 SUSFS 冲突修复。通用补丁会先应用所有兼容 hunk；出现 rejected hunk 时，工作流先检查补丁是否只是被提前完整应用。如果不是，则要求暂存的修复补丁覆盖每一个产生 `.rej` 的源码文件，再依次应用修复补丁。全部成功后状态记录为 `applied-with-device-repair`，原始 `.rej`/`.orig` 会保存到诊断目录后从源码树清理，再继续 inline hook。缺少文件覆盖或修复补丁自身失败时仍会立即终止，不会静默忽略真正缺失的 SUSFS 代码。报告会分别列出前置补丁、暂存修复补丁、实际执行修复补丁和已修复拒绝文件数量。

工作流会严格读取内核根 `Makefile` 的 `VERSION`/`PATCHLEVEL`，选择 `susfs_patch_to_<版本>.patch`。SUSFS 或 inline hook 补丁失败时，工作流会在生成报告前收集内核树中的 `.rej`、`.orig`、补丁源文件、完整应用日志和机型补丁重叠验证日志，并随构建产物上传供下载排查。启用 DroidSpaces 会从官方最新 release 下载 APK/runtime，并在 SUSFS 同时启用时显示官方兼容性警告。启用 AnyKernel3 后会按 codename、A/B 和所选 `Image.gz`/`Image.gz-dtb` 目标生成 `anykernel.sh`，并写入指定的刷入提示文案。

可用以下命令生成只包含兼容源码的上游基线补丁，默认基于 SukiSU Ultra `builtin` 提交 `6c284e957feaa9a388a9f1c37dc4ec80d95e434b`：

```sh
bash .github/scripts/generate-upstream-compat-patch.sh
```

输出文件为 `artifacts/sukisu-ultra-builtin-non-gki-compat.patch`。更新上游基线后设置 `UPSTREAM_REF` 再生成，便于审查兼容逻辑并移植到后续版本。

生成补丁前脚本会同时比较官方 `main` 的 Manager UAPI。仓库中的 `Check upstream Manager UAPI` 工作流也会每周检查一次；如果上游增加协议版本，检查会明确失败并要求先移植真实协议，防止仅修改版本号造成伪兼容。可在已拉取官方 `main` 后手动运行：

```sh
UPSTREAM_MANAGER_REF=upstream/main bash .github/scripts/check-manager-uapi-sync.sh
```

示范模板位于 `.github/workflows/temple/build-custom-kernel-example.yml`。GitHub 不会执行 `temple/` 子目录中的文件；需要实际运行时请使用根目录的活动工作流。

## 已验证配置

验证使用 clang 12、arm64 GCC 交叉工具链、`vendor/xiaomi/mi845_defconfig` 和 `vendor/xiaomi/dipper.config`。具体结果见 `docs/verification.md`。

## 许可证以及鸣谢名单

沿用上游项目的 GPL-2.0 许可证，详见 `LICENSE`。
## 🙏 鸣谢
感谢所有为本项目提供帮助、建议、代码贡献的朋友：

- [@JackA1ltMan](https://github.com/JackA1ltMan)
- [@KirinNova](https://github.com/KirinNova)
- [@ShirkNeko](https://github.com/ShirkNeko)（SukiSU上游）

> 特别感谢开源社区相关项目带来的启发。
