# pstore / ramoops 崩溃与关机前日志（4.x / GKI）

中英文工作流的 `enable_pstore_debug` 默认关闭。开启后，在最终 `.config` 中按目标源码的 Kconfig 能力配置并验证：

- `CONFIG_PRINTK=y`、`CONFIG_PSTORE=y`、`CONFIG_PSTORE_CONSOLE=y`；
- `CONFIG_PSTORE_RAM=y`；仅在厂商旧树只提供 `RAMOOPS` 时使用该符号；
- 存在 `PSTORE_PMSG` 时启用，缺失则警告并保留内核日志能力。

这里不依据 `uname` 或伪装版本选择分支，因而适用于有这些能力的 4.4/4.9/4.14/4.19 厂商树以及 5.x/6.x GKI 源码。缺少核心功能或被 `olddefconfig` 因依赖不满足而取消时会停止构建，不能用虚假的配置行宣称启用成功。关闭开关不修改源码原有 pstore 配置，也不是强行禁用 pstore。

日志功能不依赖 SukiSU、SUSFS、DroidSpaces、QCOM 或 MTK。不会强制开启 FTRACE、DEBUG_FS、全局 verbose 日志，不改变 panic-on-oops、panic timeout、watchdog、温控、WLAN 或 SELinux。console 会多一些写入保留 RAM 的开销，不持续写闪存，不安装后台轮询服务。

### Polaris / Xiaomi SDM845 专用路径

当 workflow 机型代码为 `polaris`，且目标源码同时提供并选择 `CONFIG_MACH_XIAOMI_D5X`（该符号再选择 `CONFIG_MACH_XIAOMI_SDM845`）以及该平台自己的 ramoops early-parameter/设备注册代码时，配置脚本会保留原有 `CONFIG_CMDLINE` 内容、启用 `CONFIG_CMDLINE_EXTEND=y`，并在缺失时加入该源码要求的 `ramoops_memreserve=4M`。这是源码明确提供的平台接口，不会改动 `0xB0000000` 地址，也不会向其他机型注入地址或参数。若来源/平台条件未全部满足，则 workflow 只校验 Kconfig，并在报告中标明设备 DT/平台预留内存仍待确认。

114514 的 `hyperos4-thermal-compat` 分支为 Polaris 专用 ramoops 初始化分配了独立 panic/oops record 区，旧布局将整个 4 MiB 都给 console 与 pmsg，实际没有 dmesg dump 区。新布局按总保留区划分 record、console 和 pmsg；仅当内核本来就启用了 `CONFIG_PSTORE_FTRACE` 时才划分 ftrace 区。初始化还会拒绝过小内存范围、验证该物理范围完整落在系统 RAM 内，并在 memblock 保留失败时不注册 ramoops 设备。具体分区和平台注册结果要以启动日志中的 `ramoops` 信息为准。

## 编译开启不等于设备端已持久化

必须由设备启动时实际使用的 DT/DTBO 或平台初始化提供合法且重启后保留的 ramoops 内存。至少确认：

1. 与设备真实内存布局匹配的 `reserved-memory` 区域，没有与 modem/GPU/固件等区域重叠；启用状态的 `compatible = "ramoops"` 节点及正确 `reg`。
2. 非零 `record-size` 才有 panic/oops 记录；非零 `console-size` 才有持续 console；`pmsg-size` 及 Android 向 `/dev/pmsg0` 写入的服务才有 pmsg。总大小必须满足该树 ramoops binding 的限制。
3. 不同内核的 `no-dump-oops`、`dump_oops` 或 `max-reason` 语义不同，使用目标源码对应文档，不跨版本盲目设置。
4. 内核启动日志显示 ramoops/pstore 成功注册；其他 pstore 后端或 `pstore.backend=` 参数没有抢占目标后端。能在 `/sys/fs/pstore` 挂载 pstore。

产物 `ramoops-dts-candidates.txt` **只是源码候选列表**，可能属于其他设备或 disabled 节点，不能据此宣布本机已就绪。列表为空也可能是节点由外部 vendor DTBO 或平台代码提供。工作流不自动写入猜测的物理地址、不改变内存大小、不改 DT/DTBO、不强制 ramoops 参数。缺少节点时须按机型单独适配。

对于 GKI，boot 内的通用内核与设备 vendor_boot/DTBO 配合；本开关只提供配置辅助，不把现有 Non-GKI/Clang 12 工作流变成通用 GKI 构建系统。仍需匹配该 GKI 分支的工具链、构建规则、ABI/KMI 和设备打包方式。4.x 或 GKI 都不能仅凭版本号保证实机有效。

## 自动记录能做什么

后端正确注册且缓冲区非零时，pstore console **由内核自动持续记录**最近的 printk，包括正常关机前的内核消息；panic/oops 按目标内核的 dump 策略记录，复位后可读取。无需手机在出问题时仍连着 ADB，也不依赖关机前还能执行用户脚本。

这不是完整 logcat 自动备份，也不保证记录一个已死锁、没有输出任何日志的黑屏原因。正常关机不一定有 `dmesg-ramoops-*` crash record，可检查 `console-ramoops-*`。突然断电、PMIC/电池保护关机、bootloader 清 RAM、再次启动覆盖缓冲区都可能丢失记录。RAM 后端不能保证跨冷启动保存；不要为“必定有日志”而自动制造 panic 或关闭保护。

## 下载产物与收集实机日志

Actions 无论构建成功还是失败都会尽量提供 `pstore-debug/`，包含有效配置 `kernel.config`（若已生成）、pstore 配置摘要、状态、DTS 候选、本文档和一次性采集脚本；这些是构建诊断，并非尚未刷机设备的崩溃日志。构建报告还包含请求/配置/后端/设备树状态和文件校验值。

复现后尽快进入能读保留区的系统或 recovery，避免反复重启。Android 已有 root 时：

```sh
adb push collect-pstore.sh /data/local/tmp/collect-pstore.sh
adb shell su -c 'sh /data/local/tmp/collect-pstore.sh'
# 按上一步打印的实际目录执行 adb pull；若权限不足可在 root recovery 中拉取。
```

root recovery 中（即使 data 未解密也可暂存于 /tmp）：

```sh
adb push collect-pstore.sh /tmp/collect-pstore.sh
adb shell sh /tmp/collect-pstore.sh /tmp
adb pull /tmp/pstore-实际时间-随机后缀
```

脚本只挂载/读取 pstore 并复制记录，**不删除原记录**，每次创建独立目录；还采集当次启动 dmesg/logcat、启动原因及可用的 last_kmsg。当次 logcat 不等于上次崩溃日志。若 ROM/init 已转存并清除了记录，还要检查该 ROM 的日志存档。无记录不能反证没有崩溃。

分享前检查日志隐私（设备标识、应用活动、网络信息）。不要放宽 SELinux 或对 pstore 设置全局可读；使用 root/recovery 获取，权限受限时保留错误信息排查。

## 官方参考

- [Linux ramoops 文档](https://docs.kernel.org/admin-guide/ramoops.html)
- [Linux 4.19 ramoops 文档](https://www.kernel.org/doc/html/v4.19/admin-guide/ramoops.html)
- [Linux ramoops DT binding](https://github.com/torvalds/linux/blob/master/Documentation/devicetree/bindings/reserved-memory/ramoops.yaml)

实际优先阅读目标内核的 `Documentation/admin-guide/ramoops.rst`、旧版 `Documentation/ramoops.txt`、对应 binding 和 `fs/pstore/Kconfig`。
