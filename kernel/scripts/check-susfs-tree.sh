#!/bin/sh
# Validate the SUSFS core ABI before compiling KernelSU's inline-hook path.
set -eu

root=${1:?usage: check-susfs-tree.sh KERNEL_SOURCE_ROOT}
fail() { echo "[KSU SUSFS] $*" >&2; exit 1; }

for path in fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h; do
    [ -r "$root/$path" ] || fail "missing $path; apply the matching kernel-series SUSFS patch first"
done

version=$(sed -n 's/^[[:space:]]*#define[[:space:]]*SUSFS_VERSION[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$root/include/linux/susfs.h" | head -n 1)
[ -n "$version" ] || fail 'SUSFS_VERSION is absent from include/linux/susfs.h'

grep -Eq 'void[[:space:]]+susfs_init[[:space:]]*\(' "$root/include/linux/susfs.h" ||
    fail 'susfs_init declaration is missing'
for name in susfs_set_current_proc_no_su susfs_is_current_proc_no_su \
            susfs_set_current_proc_umounted susfs_set_current_proc_umounted_for_zygote_next; do
    grep -Eq "[[:space:]]$name[[:space:]]*\\(" "$root/include/linux/susfs_def.h" ||
        fail "$name is missing from susfs_def.h"
done

case "$version" in
    v2.3.*) echo "$version" ;;
    *) echo "[KSU SUSFS] $version has the required core hooks, but only v2.3.x is targeted by this dev check" >&2
       echo "$version" ;;
esac
