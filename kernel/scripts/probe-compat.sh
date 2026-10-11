#!/bin/sh
# Build-time probes for vendor Non-GKI trees. Never infer an ABI from uname.
set -eu

root=${1:?usage: probe-compat.sh KERNEL_SOURCE_ROOT}
fail() { echo "[KSU compat] $*" >&2; exit 1; }

# Join declarations split across lines and ignore commented-out prototypes.
compact_c() {
    awk '
        { sub(/\/\/.*$/, ""); text = text " " $0 }
        END {
            while (match(text, /\/\*([^*]|\*+[^*/])*\*+\//))
                text = substr(text, 1, RSTART - 1) " " substr(text, RSTART + RLENGTH)
            gsub(/[[:space:]]+/, " ", text)
            print text
        }
    ' "$@"
}

if [ -r "$root/include/linux/lsm_hooks.h" ]; then
    lsm=$(compact_c "$root/include/linux/lsm_hooks.h")
    if [ -r "$root/include/linux/lsm_hook_defs.h" ]; then
        lsm="$lsm $(compact_c "$root/include/linux/lsm_hook_defs.h")"
    fi
else
    [ -r "$root/include/linux/security.h" ] || fail 'missing LSM headers'
    lsm=$(compact_c "$root/include/linux/security.h")
fi

has_lsm() { printf '%s\n' "$lsm" | grep -Eq "$1"; }
if has_lsm 'struct security_hook_list[[:space:]]*\{'; then
    echo -DKSU_COMPAT_HAS_LIST_OF_LSM_HOOKS
fi
if has_lsm 'struct hlist_node[[:space:]]+list[[:space:]]*;'; then
    echo -DKSU_COMPAT_HLIST_FOR_SECURITY_HOOK_LIST
fi
if has_lsm 'char[[:space:]]*\*[[:space:]]*lsm[[:space:]]*;'; then
    echo -DKSU_COMPAT_REQUIRE_PROVIDE_LSM_NAME
fi

# Both pre-5.1 function pointers and backported LSM_HOOK() declarations occur
# in 4.9/4.14/4.19 trees. Unknown prototypes must not silently select an ABI.
if has_lsm '(\(\*setprocattr\)[[:space:]]*\(|LSM_HOOK\([^,]+,[^,]+,[[:space:]]*setprocattr,)[[:space:]]*const char[[:space:]]*\*'; then
    echo -DKSU_COMPAT_SETPROCATTR_USE_NEW_PROTOTYPE
elif ! has_lsm '(\(\*setprocattr\)[[:space:]]*\(|LSM_HOOK\([^,]+,[^,]+,[[:space:]]*setprocattr,)[[:space:]]*struct task_struct[[:space:]]*\*'; then
    fail 'unrecognized setprocattr prototype; inspect vendor LSM headers before building'
fi

[ -r "$root/include/linux/fs.h" ] || fail 'missing include/linux/fs.h'
fs=$(compact_c "$root/include/linux/fs.h")
for api in read write; do
    if printf '%s\n' "$fs" | grep -Eq "(^|[[:space:]])kernel_${api}[[:space:]]*\([^;{}]*loff_t[[:space:]]*\*[^;{}]*\)"; then
        case "$api" in
            read) echo -DKSU_HAS_KERNEL_READ_POS ;;
            write) echo -DKSU_HAS_KERNEL_WRITE_POS ;;
        esac
    fi
done

if [ -r "$root/include/linux/fdtable.h" ]; then
    if compact_c "$root/include/linux/fdtable.h" | grep -Eq '(^|[[:space:]])close_fd[[:space:]]*\([[:space:]]*unsigned'; then
        echo -DKSU_HAS_CLOSE_FD
    fi
fi
