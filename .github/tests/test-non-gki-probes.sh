#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
probe="$repo/kernel/scripts/probe-compat.sh"
fixture=$(mktemp -d)
trap 'case "$fixture" in /tmp/tmp.*) rm -rf -- "$fixture" ;; esac' EXIT
mkdir -p "$fixture/include/linux"

cat > "$fixture/include/linux/lsm_hooks.h" <<'EOF'
struct security_hook_list {
    struct list_head list;
    union {
        int (*setprocattr)(struct task_struct *p, char *name,
                           void *value, size_t size);
    } hook;
};
EOF
cat > "$fixture/include/linux/fs.h" <<'EOF'
extern ssize_t kernel_read(struct file *, loff_t, char *, unsigned long);
extern ssize_t kernel_write(struct file *, const char *, size_t, loff_t);
extern ssize_t __kernel_write(struct file *, const char *, size_t, loff_t *);
EOF
printf 'extern int __close_fd(struct files_struct *, unsigned int);\n' > "$fixture/include/linux/fdtable.h"
actual=$(sh "$probe" "$fixture")
[[ "$actual" == '-DKSU_COMPAT_HAS_LIST_OF_LSM_HOOKS' ]] || {
    echo "legacy ABI misdetected: $actual" >&2
    exit 1
}

cat > "$fixture/include/linux/lsm_hooks.h" <<'EOF'
struct security_hook_list {
    struct hlist_node list;
    char *lsm;
};
/* Do not infer the setprocattr signature from this comment:
   int (*setprocattr)(struct task_struct *p, char *name, void *value, size_t size); */
EOF
cat > "$fixture/include/linux/lsm_hook_defs.h" <<'EOF'
LSM_HOOK(int, -EINVAL, setprocattr,
         const char *name, void *value, size_t size)
EOF
cat > "$fixture/include/linux/fs.h" <<'EOF'
extern ssize_t kernel_read(struct file *, void *, size_t, loff_t *);
extern ssize_t kernel_write(struct file *, const char *, size_t, loff_t);
EOF
printf 'extern int close_fd(unsigned fd);\n' > "$fixture/include/linux/fdtable.h"
actual=$(sh "$probe" "$fixture")
expected=$(printf '%s\n' \
    -DKSU_COMPAT_HAS_LIST_OF_LSM_HOOKS \
    -DKSU_COMPAT_HLIST_FOR_SECURITY_HOOK_LIST \
    -DKSU_COMPAT_REQUIRE_PROVIDE_LSM_NAME \
    -DKSU_COMPAT_SETPROCATTR_USE_NEW_PROTOTYPE \
    -DKSU_HAS_KERNEL_READ_POS \
    -DKSU_HAS_CLOSE_FD)
[[ "$actual" == "$expected" ]] || {
    echo "backported ABI misdetected: $actual" >&2
    exit 1
}

printf '/* no setprocattr */\n' > "$fixture/include/linux/lsm_hook_defs.h"
if sh "$probe" "$fixture" > /dev/null 2>&1; then
    echo 'unknown LSM ABI was accepted' >&2
    exit 1
fi

echo '[+] Non-GKI vendor API probe tests passed'
