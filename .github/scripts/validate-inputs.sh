#!/usr/bin/env bash
set -euo pipefail
die() { echo "[ERROR] $*" >&2; exit 1; }
: "${CODENAME:?CODENAME is required}"
: "${KERNEL_REPO:?KERNEL_REPO is required}"
[[ "$CODENAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "codename contains unsupported characters"
[[ "$KERNEL_REPO" == *.git ]] || die "kernel repository must be a complete .git URL"
[[ -n "${AUTHOR:-}" ]] || die "author must not be empty"
[[ -z "${DEFCONFIG:-}" || "$DEFCONFIG" == *_defconfig ]] || die "defconfig must end with _defconfig"
[[ -z "${DEVICE_CONFIG:-}" || "$DEVICE_CONFIG" == *.config ]] || die "device config must end with .config"
[[ "${BUILD_TARGET:-Image.gz-dtb}" == Image.gz || "${BUILD_TARGET:-Image.gz-dtb}" == Image.gz-dtb ]] || die 'build target must be Image.gz or Image.gz-dtb'
[[ "${AK3_KERNEL_TARGET:-Image.gz-dtb}" == Image.gz || "${AK3_KERNEL_TARGET:-Image.gz-dtb}" == Image.gz-dtb ]] || die 'AnyKernel3 target must be Image.gz or Image.gz-dtb'
[[ -z "${BUILD_TIME:-}" || "$BUILD_TIME" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}([T ][0-9]{2}:[0-9]{2}(:[0-9]{2})?(Z|[+-][0-9]{2}:[0-9]{2})?)?$ ]] || die "build time must be ISO-8601"
for name in ENABLE_PSTORE_DEBUG SPOOF_KERNEL_VERSION AB_PARTITION DISABLE_LTO_REQUESTED IGNORE_WERROR_REQUESTED FORCE_SELINUX_ENFORCING INTEGRATE_SUSFS INTEGRATE_DROIDSPACES PACKAGE_AK3 APPLY_DEVICE_PATCHES; do case "${!name:-false}" in true|false) ;; *) die "$name must be true or false" ;; esac; done
if [[ "${SPOOF_KERNEL_VERSION:-false}" == true ]]; then
  [[ "${SPOOFED_KERNEL_VERSION:-}" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] || die 'spoofed kernel version must use numeric major.minor.sublevel format, for example 4.9.337'
elif [[ -n "${SPOOFED_KERNEL_VERSION:-}" ]]; then
  echo '[WARNING] spoofed kernel version is ignored because spoof_kernel_version=false' >&2
fi
if [[ "${APPLY_DEVICE_PATCHES:-false}" == true ]]; then
  [[ "${DEVICE_PATCH_REPO:-}" == *.git ]] || die 'device patch repository must be a complete .git URL'
  [[ "${DEVICE_PATCH_BRANCH:-}" =~ ^[A-Za-z0-9._/-]+$ && "${DEVICE_PATCH_BRANCH}" != -* && "${DEVICE_PATCH_BRANCH}" != */ && "${DEVICE_PATCH_BRANCH}" != /* ]] || die 'device patch branch must be a valid branch name'
  [[ -n "${DEVICE_PATCH_NAMES:-}" ]] || die 'device patch names are required when device patches are enabled'
  for patch_name in ${DEVICE_PATCH_NAMES}; do
    [[ "$patch_name" != -* && "$patch_name" != */* && "$patch_name" != *..* ]] || die "invalid device patch filename: $patch_name"
  done
else
  [[ -z "${DEVICE_PATCH_REPO:-}" && -z "${DEVICE_PATCH_NAMES:-}" ]] || echo '[WARNING] device patch inputs are ignored because apply_device_patches=false' >&2
fi
export KERNEL_NAME=${KERNEL_NAME:-by_XiZi} KERNEL_VERSION=${KERNEL_VERSION:-v1.0} ARCH=${ARCH:-arm64} BUILD_TARGET=${BUILD_TARGET:-Image.gz-dtb} OUT_DIR=${OUT_DIR:-out}
printf '[+] Inputs validated: %s (%s), defconfig=%s, config=%s\n' "$CODENAME" "$KERNEL_REPO" "${DEFCONFIG:-auto}" "${DEVICE_CONFIG:-none}"
