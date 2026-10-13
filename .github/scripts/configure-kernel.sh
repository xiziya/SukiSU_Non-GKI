#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "${KERNEL_ROOT:?}"; out=${OUT_DIR:-out}; export OUT_DIR="$out"
export ARCH=${ARCH:-arm64}
export SUBARCH=${SUBARCH:-$ARCH}
export KBUILD_BUILD_USER=${AUTHOR:-XiZi} KBUILD_BUILD_HOST=GitHub-Actions KBUILD_BUILD_TIMESTAMP=${BUILD_TIME:-$(date -u '+%Y-%m-%d %H:%M:%S')}
# Some non-GKI arm64 kernels (including 4.9 trees) validate the 32-bit
# compat-vDSO toolchain while parsing the Makefile during configuration.
# Keep defaults here so the script also works outside GitHub Actions, while
# allowing callers to provide a different cross toolchain through the env.
export CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
export CROSS_COMPILE_ARM32=${CROSS_COMPILE_ARM32:-arm-linux-gnueabi-}
export CLANG_TRIPLE=${CLANG_TRIPLE:-aarch64-linux-gnu-}
# The workflow produces an explicitly named release.  Mark LOCALVERSION as
# defined-but-empty so scripts/setlocalversion does not append '+' for an
# integrated (and therefore intentionally modified) source tree.
export LOCALVERSION=
mkdir -p "$out"
# Only the resolved defconfig is a make target. User/device and DroidSpaces
# files are Kconfig fragments and must be merged after the base defconfig;
# passing them to make makes older trees enter an interactive config restart.
config_targets=("${DEFCONFIG_RESOLVED:?}")
kernelrelease_args=()
[[ -n "${KERNELRELEASE_OVERRIDE_BASE:-}" ]] && kernelrelease_args+=("KERNELRELEASE=${KERNELRELEASE_OVERRIDE_BASE}")
if [[ -n "${GITHUB_ENV:-}" ]]; then printf 'OUT_DIR=%s\nLOCALVERSION=\n' "$OUT_DIR" >> "$GITHUB_ENV"; fi

# CIP kernels may ship release-channel fragments such as localversion-cip and
# localversion-st.  They are useful to the upstream release process, but they
# duplicate the workflow's explicit CONFIG_LOCALVERSION and can push UTS_RELEASE
# beyond its hard 64-byte limit.  Preserve the files under names that are not
# consumed by scripts/setlocalversion instead of deleting them.
vendor_localversion_status=not-present
for localversion_file in "$KERNEL_ROOT"/localversion-cip* "$KERNEL_ROOT"/localversion-st*; do
  [[ -f "$localversion_file" ]] || continue
  localversion_name=$(basename "$localversion_file")
  mv "$localversion_file" "$KERNEL_ROOT/.sukisu-disabled-$localversion_name"
  vendor_localversion_status=suppressed
  echo "[+] suppressed vendor release fragment: $localversion_name"
done
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'VENDOR_LOCALVERSION_STATUS=%s\n' "$vendor_localversion_status" >> "$GITHUB_ENV"
fi

# A few vendor/non-GKI trees carry scripts/as-version.sh without the helper
# introduced alongside it.  Kconfig invokes as-version.sh while loading the
# defconfig, so a missing helper is reported misleadingly as an unsupported
# assembler.  Restore only the missing helper; never replace a kernel-provided
# version policy.
tool_version_helper="$KERNEL_ROOT/scripts/min-tool-version.sh"
if [[ -f "$tool_version_helper" ]]; then
  chmod +x "$tool_version_helper"
  tool_version_status=present
else
  mkdir -p "$(dirname "$tool_version_helper")"
  printf '%s\n' \
    '#!/bin/sh' \
    '# Compatibility helper for vendor/non-GKI trees missing min-tool-version.sh.' \
    'set -e' \
    'if [ "$#" -ne 1 ]; then' \
    '  echo "Usage: $0 toolname" >&2' \
    '  exit 1' \
    'fi' \
    'case "$1" in' \
    'binutils) echo 2.23.0 ;;' \
    'gcc) echo 5.1.0 ;;' \
    'icc) echo 16.0.3 ;;' \
    'llvm|clang) echo 10.0.1 ;;' \
    '*) echo "$1: unknown tool" >&2; exit 1 ;;' \
    'esac' > "$tool_version_helper"
  chmod +x "$tool_version_helper"
  tool_version_status=restored
  echo "[WARN] restored missing scripts/min-tool-version.sh for this legacy kernel tree"
fi
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'MIN_TOOL_VERSION_STATUS=%s\n' "$tool_version_status" >> "$GITHUB_ENV"
fi
echo "[+] min-tool-version.sh: $tool_version_status"

make O="$out" "${kernelrelease_args[@]}" "${config_targets[@]}"
set_config() {
  local key=$1 value=$2
  sed -i -E "/^(# )?${key}(=.*| is not set)$/d" "$out/.config"
  if [[ "$value" == n ]]; then
    printf '# %s is not set\n' "$key" >> "$out/.config"
  else
    printf '%s=%s\n' "$key" "$value" >> "$out/.config"
  fi
}
apply_config_fragment() {
  local fragment=$1 line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^(CONFIG_[A-Za-z0-9_]+)=(y|m|n)$ ]] || continue
    key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}
    set_config "$key" "$value"
  done < "$fragment"
}
# Apply optional fragments only after the base defconfig has created a valid
# output .config. This keeps legacy/non-GKI Kconfig flows non-interactive.
if [[ -n "${DEVICE_CONFIG_RESOLVED:-}" ]]; then
  device_fragment="$DEVICE_CONFIG_RESOLVED"
  [[ -f "$device_fragment" ]] || device_fragment="arch/${ARCH:-arm64}/configs/$device_fragment"
  [[ -f "$device_fragment" ]] || { echo "[ERROR] config fragment not found: $DEVICE_CONFIG_RESOLVED" >&2; exit 1; }
  apply_config_fragment "$device_fragment"
fi
# Integration changes add Kconfig entries after the vendor defconfig has been
# loaded. Explicitly enable the requested KernelSU/SUSFS features in the
# generated output config so a vendor '# CONFIG_KSU is not set' cannot disable
# the integrated driver. The source defconfig remains untouched.
if [[ "${INTEGRATE_SUSFS:-false}" == true ]]; then
  set_config CONFIG_KSU y
  set_config CONFIG_KSU_SUSFS y
  set_config CONFIG_KSU_SUSFS_SUS_PATH y
  set_config CONFIG_KSU_SUSFS_SUS_MOUNT y
  set_config CONFIG_KSU_SUSFS_SUS_KSTAT y
  set_config CONFIG_KSU_SUSFS_SPOOF_UNAME y
  set_config CONFIG_KSU_SUSFS_ENABLE_LOG y
  set_config CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS y
  set_config CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG y
  set_config CONFIG_KSU_SUSFS_OPEN_REDIRECT y
  set_config CONFIG_KSU_SUSFS_SUS_MAP y
fi
if [[ "${INTEGRATE_DROIDSPACES:-false}" == true ]]; then
  droidspaces_fragment="arch/${ARCH:-arm64}/configs/droidspaces.config"
  [[ -f "$droidspaces_fragment" ]] || { echo "[ERROR] DroidSpaces config fragment is missing: $droidspaces_fragment" >&2; exit 1; }
  apply_config_fragment "$droidspaces_fragment"
  # Official Non-GKI guidance requires user namespaces for safe procfs access
  # inside containers. Older third-party fragments omitted this option.
  set_config CONFIG_USER_NS y
fi
if [[ "${DISABLE_LTO_REQUESTED:-false}" == true ]]; then for key in CONFIG_LTO CONFIG_LTO_CLANG CONFIG_LTO_CLANG_THIN CONFIG_LTO_CLANG_FULL CONFIG_THINLTO; do sed -i "s/^${key}=y/# ${key} is not set/" "$out/.config"; done; echo CONFIG_LTO_NONE=y >> "$out/.config"; fi
if [[ "${IGNORE_WERROR_REQUESTED:-false}" == true ]]; then
  # Disable the kernel-level CONFIG_CC_WERROR guard as well as appending
  # -Wno-error during compilation. This covers both global and per-warning
  # -Werror flags in old vendor Kbuild files without changing source code.
  set_config CONFIG_CC_WERROR n
fi
# CONFIG_SECURITY_SELINUX_DEVELOP makes SELinux start permissive unless the
# boot command line explicitly contains enforcing=1. Some Android vendor boot
# images do not pass that parameter, which leaves /sys/fs/selinux/enforce at 0.
# Apply the deterministic configuration fix only when explicitly requested;
# otherwise preserve the kernel tree's original SELinux policy completely.
selinux_enforcing_status=unchanged
selinux_source_repair_status=not-requested
if [[ "${FORCE_SELINUX_ENFORCING:-false}" == true ]]; then
  selinuxfs=security/selinux/selinuxfs.c
  [[ -f "$selinuxfs" ]] || {
    echo "[ERROR] SELinux enforcing was requested, but $selinuxfs is missing" >&2
    exit 1
  }
  enforce_writer=$(sed -n '/static ssize_t sel_write_enforce/,/^}/p' "$selinuxfs")
  if grep -Eq '^[[:space:]]*new_value[[:space:]]*=[[:space:]]*0[[:space:]]*;' <<< "$enforce_writer"; then
    sed -i -E '/static ssize_t sel_write_enforce/,/^}/{s/^([[:space:]]*)new_value[[:space:]]*=[[:space:]]*0[[:space:]]*;.*$/\1new_value = !!new_value;/;}' "$selinuxfs"
    selinux_source_repair_status=repaired-forced-permissive
    echo '[+] restored the standard SELinux enforce writer after detecting a forced-permissive source hack'
  elif grep -Eq '^[[:space:]]*new_value[[:space:]]*=[[:space:]]*!!new_value[[:space:]]*;' <<< "$enforce_writer"; then
    selinux_source_repair_status=standard
  else
    selinux_source_repair_status=unrecognized
    echo '[ERROR] SELinux enforce writer does not contain a recognized standard or forced-permissive assignment' >&2
    exit 1
  fi
  set_config CONFIG_SECURITY_SELINUX y
  set_config CONFIG_SECURITY_SELINUX_DEVELOP n
  selinux_enforcing_status=requested
  echo '[+] requested fixed SELinux enforcing mode by disabling development support'
fi
# Some vendor SDM845 trees keep the TAS2557 caller enabled while leaving the
# speaker-ID provider as an optional MFD symbol. That combination compiles all
# objects but fails at the final vmlinux link with an undefined
# spk_id_get_pin_3state symbol. Enable the provider only when this exact source
# level dependency is present; unrelated kernels remain unchanged.
spk_id_status=not-needed
if [[ -f drivers/mfd/spk-id.c && -f drivers/mfd/Makefile && \
      -f techpack/audio/asoc/codecs/tas2557/tas2557-core.c && \
      -f drivers/mfd/Kconfig ]] && \
   grep -q 'CONFIG_MFD_SPK_ID.*spk-id\.o' drivers/mfd/Makefile && \
   grep -q 'config MFD_SPK_ID' drivers/mfd/Kconfig && \
   grep -q 'spk_id_get_pin_3state' techpack/audio/asoc/codecs/tas2557/tas2557-core.c; then
  set_config CONFIG_MFD_SPK_ID y
  spk_id_status=enabled
  echo '[+] enabled CONFIG_MFD_SPK_ID for the TAS2557 speaker-ID provider dependency'
fi
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'VENDOR_SPK_ID_STATUS=%s\n' "$spk_id_status" >> "$GITHUB_ENV"
fi

# Android vendor partitions normally load qcacld as a release-matched module.
# A custom localversion makes that stock module unusable, while a generic AK3
# package cannot reliably update Android's modules.load/vendor_dlkm metadata.
# Build the driver into the kernel when this complete Qualcomm layout exists.
wlan_driver_status=not-present
wlan_root=drivers/staging/qcacld-3.0
if [[ -f "$wlan_root/Kconfig" && -f "$wlan_root/Kbuild" && \
      -d drivers/staging/qca-wifi-host-cmn && -d drivers/staging/fw-api ]] && \
   grep -q '^config QCA_CLD_WLAN$' "$wlan_root/Kconfig"; then
  broken_gpio_include='-I $(srctree)/$(WLAN_COMMON_INC)/$(UMAC_TARGET_GPIO_INC)'
  if grep -Fq -- "$broken_gpio_include" "$wlan_root/Kbuild"; then
    sed -i 's|-I $(srctree)/$(WLAN_COMMON_INC)/$(UMAC_TARGET_GPIO_INC)|$(UMAC_TARGET_GPIO_INC)|' "$wlan_root/Kbuild"
    grep -Fq -- "$broken_gpio_include" "$wlan_root/Kbuild" && {
      echo '[ERROR] failed to repair malformed qcacld GPIO include path' >&2
      exit 1
    }
    echo '[+] repaired malformed qcacld GPIO include path'
  fi
  set_config CONFIG_QCA_CLD_WLAN y
  wlan_driver_status=builtin-requested
  echo '[+] requested built-in Qualcomm qcacld WLAN driver'
fi

# Apply after all user/integration fragments; olddefconfig resolves dependencies.
bash "$script_dir/configure-pstore.sh" prepare

date_part=$(date -u -d "$KBUILD_BUILD_TIMESTAMP" +%Y%m%d 2>/dev/null || date -u +%Y%m%d); local="-${KERNEL_NAME:-by_XiZi}-${KERNEL_VERSION:-v1.0}-$date_part"
sed -i '/^CONFIG_LOCALVERSION=/d' "$out/.config"; printf 'CONFIG_LOCALVERSION="%s"\n' "$local" >> "$out/.config"
# Never append -g<commit>-dirty: all integrations intentionally change the
# ephemeral clone and the workflow already supplies a deterministic suffix.
set_config CONFIG_LOCALVERSION_AUTO n
if [[ -n "${KERNELRELEASE_OVERRIDE_BASE:-}" ]]; then
  kernelrelease_args=("KERNELRELEASE=${KERNELRELEASE_OVERRIDE_BASE}${local}")
fi
make O="$out" "${kernelrelease_args[@]}" olddefconfig
if [[ "$selinux_enforcing_status" == requested ]]; then
  grep -q '^CONFIG_SECURITY_SELINUX=y$' "$out/.config" || {
    echo '[ERROR] SELinux enforcing was requested, but Kconfig did not retain CONFIG_SECURITY_SELINUX=y' >&2
    exit 1
  }
  grep -q '^# CONFIG_SECURITY_SELINUX_DEVELOP is not set$' "$out/.config" || {
    echo '[ERROR] SELinux enforcing was requested, but Kconfig did not disable CONFIG_SECURITY_SELINUX_DEVELOP' >&2
    exit 1
  }
  selinux_enforcing_status=forced
fi
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'SELINUX_ENFORCING_STATUS=%s\nSELINUX_SOURCE_REPAIR_STATUS=%s\n' \
    "$selinux_enforcing_status" "$selinux_source_repair_status" >> "$GITHUB_ENV"
fi
if [[ "$wlan_driver_status" == builtin-requested ]]; then
  grep -q '^CONFIG_QCA_CLD_WLAN=y$' "$out/.config" || {
    echo '[ERROR] qcacld is present, but Kconfig did not retain CONFIG_QCA_CLD_WLAN=y' >&2
    exit 1
  }
  wlan_driver_status=builtin
fi
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'WLAN_DRIVER_STATUS=%s\n' "$wlan_driver_status" >> "$GITHUB_ENV"
fi
if [[ "$spk_id_status" == enabled ]]; then
  grep -q '^CONFIG_MFD_SPK_ID=y$' "$out/.config" || {
    echo '[ERROR] TAS2557 requires CONFIG_MFD_SPK_ID, but Kconfig did not retain it' >&2
    exit 1
  }
fi
if [[ "${INTEGRATE_SUSFS:-false}" == true ]]; then
  required_configs=(
    CONFIG_KSU CONFIG_KSU_SUSFS CONFIG_KSU_SUSFS_SUS_PATH
    CONFIG_KSU_SUSFS_SUS_MOUNT CONFIG_KSU_SUSFS_SUS_KSTAT
    CONFIG_KSU_SUSFS_SPOOF_UNAME CONFIG_KSU_SUSFS_ENABLE_LOG
    CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
    CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
    CONFIG_KSU_SUSFS_OPEN_REDIRECT CONFIG_KSU_SUSFS_SUS_MAP
  )
  for key in "${required_configs[@]}"; do
    grep -q "^${key}=y$" "$out/.config" || {
      echo "[ERROR] integrated configuration did not enable ${key}; check its Kconfig dependencies" >&2
      exit 1
    }
  done
  if grep -Rqs '^config KSU_MANUAL_HOOK$' drivers/kernelsu; then
    set_config CONFIG_KSU_MANUAL_HOOK y
    make O="$out" olddefconfig
  else
    echo '[INFO] CONFIG_KSU_MANUAL_HOOK is not defined by this SukiSU Ultra source; SUSFS inline hooks remain enabled.'
  fi
fi
if [[ "${INTEGRATE_DROIDSPACES:-false}" == true ]]; then
  droidspaces_required_configs=(
    CONFIG_NAMESPACES CONFIG_PID_NS CONFIG_UTS_NS CONFIG_IPC_NS
    CONFIG_SECCOMP CONFIG_SECCOMP_FILTER CONFIG_CGROUPS
    CONFIG_CGROUP_DEVICE CONFIG_CGROUP_PIDS CONFIG_MEMCG CONFIG_USER_NS
    CONFIG_CGROUP_SCHED CONFIG_CGROUP_FREEZER CONFIG_DEVTMPFS
    CONFIG_OVERLAY_FS CONFIG_NET_NS CONFIG_VETH CONFIG_BRIDGE
    CONFIG_NETFILTER CONFIG_NF_CONNTRACK CONFIG_IP_NF_IPTABLES
  )
  for key in "${droidspaces_required_configs[@]}"; do
    grep -q "^${key}=y$" "$out/.config" || {
      echo "[ERROR] DroidSpaces configuration did not enable ${key}; check this kernel's Kconfig dependencies" >&2
      exit 1
    }
  done
fi
# Validate after the final olddefconfig, including the optional manual hook pass.
bash "$script_dir/configure-pstore.sh" verify
release=$(make O="$out" "${kernelrelease_args[@]}" -s kernelrelease); [[ ${#release} -le 64 ]] || { echo "[ERROR] kernelrelease is ${#release} characters (>64): $release" >&2; exit 1; }; echo "KERNEL_RELEASE=$release" >> "$GITHUB_ENV"
