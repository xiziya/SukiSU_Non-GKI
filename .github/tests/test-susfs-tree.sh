#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
check="$repo/kernel/scripts/check-susfs-tree.sh"
fixture=$(mktemp -d)
trap 'case "$fixture" in /tmp/tmp.*) rm -rf -- "$fixture" ;; esac' EXIT
mkdir -p "$fixture/fs" "$fixture/include/linux"

printf 'void susfs_init(void) {}\n' > "$fixture/fs/susfs.c"
cat > "$fixture/include/linux/susfs.h" <<'EOF'
#define SUSFS_VERSION "v2.3.0"
void susfs_init(void);
EOF
cat > "$fixture/include/linux/susfs_def.h" <<'EOF'
static inline void susfs_set_current_proc_no_su(void) {}
static inline bool susfs_is_current_proc_no_su(void) { return false; }
static inline void susfs_set_current_proc_umounted(void) {}
static inline void susfs_set_current_proc_umounted_for_zygote_next(void) {}
EOF
[[ $(sh "$check" "$fixture") == v2.3.0 ]] || {
    echo 'SUSFS 2.3 ABI rejected' >&2
    exit 1
}

printf '/* absent */\n' > "$fixture/include/linux/susfs_def.h"
if sh "$check" "$fixture" > /dev/null 2>&1; then
    echo 'incomplete SUSFS ABI accepted' >&2
    exit 1
fi

if [[ -n ${SUSFS_PATCH:-} ]]; then
    mkdir -p "$fixture/vendor"
    (
        cd "$fixture/vendor"
        git apply --include=fs/susfs.c --include=include/linux/susfs.h \
            --include=include/linux/susfs_def.h "$SUSFS_PATCH"
    )
    sh "$check" "$fixture/vendor"
fi

echo '[+] SUSFS tree ABI checks passed'
