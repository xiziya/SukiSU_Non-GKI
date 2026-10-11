#!/usr/bin/env bash
set -euo pipefail

upstream_ref=${UPSTREAM_MANAGER_REF:-upstream/main}
local_header=kernel/include/uapi/supercall.h

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

git rev-parse --verify "$upstream_ref^{commit}" >/dev/null 2>&1 ||
  die "manager reference is unavailable: $upstream_ref (fetch the official main branch first)"

extract_version() {
  sed -n -E \
    's/.*KERNEL_SU_UAPI_VERSION[^0-9]*([0-9]+).*/\1/p' | head -n1
}

upstream_header=$(git show "$upstream_ref:uapi/supercall.h")
upstream_version=$(printf '%s\n' "$upstream_header" | extract_version)
local_version=$(extract_version < "$local_header")

[[ -n "$upstream_version" ]] || die "cannot parse UAPI version from $upstream_ref:uapi/supercall.h"
[[ -n "$local_version" ]] || die "cannot parse UAPI version from $local_header"

if [[ "$local_version" != "$upstream_version" ]]; then
  die "manager UAPI mismatch: local=$local_version upstream=$upstream_version; port the protocol before bumping the local declaration"
fi

if (( local_version >= 3 )); then
  grep -q 'ksu_install_su_fd' kernel/supercall/supercall.c || die 'UAPI 3 is declared without scoped su-session fd support'
  grep -q 'allow_su_session' kernel/supercall/dispatch.c || die 'UAPI 3 is declared without scoped ioctl permissions'
fi

if (( local_version >= 4 )); then
  grep -q 'KSU_GET_INFO_FLAG_BUNDLED' "$local_header" || die 'UAPI 4 is declared without the bundled-LKM flag'
fi

if (( local_version >= 5 )); then
  grep -q 'EVENT_SERVICES' "$local_header" || die 'UAPI 5 is declared without the services event'
  grep -q 'services_started = false' kernel/supercall/dispatch.c ||
    die 'UAPI 5 is declared without a services reset on post-fs-data'
  grep -q 'case EVENT_SERVICES:' kernel/supercall/dispatch.c ||
    die 'UAPI 5 is declared without the services event handler'
  grep -A8 'case EVENT_SERVICES:' kernel/supercall/dispatch.c | grep -q 'return 1;' ||
    die 'UAPI 5 is declared without the start/skip result'
fi

echo "[+] Manager UAPI $local_version matches $upstream_ref"
