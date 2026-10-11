#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"

header=kernel/include/uapi/supercall.h

grep -Eq 'KERNEL_SU_UAPI_VERSION, 5\)' "$header"
grep -Eq 'KSU_GET_INFO_FLAG_BUNDLED, \(1U << 4\)\)' "$header"
grep -Eq 'EVENT_SERVICES, 4\)' "$header"
grep -A8 'case EVENT_SERVICES:' kernel/supercall/dispatch.c | grep -q 'return 1;'
grep -q 'struct ksu_driver_context' kernel/supercall/supercall.c
grep -q 'ksu_install_su_fd' kernel/supercall/supercall.c
grep -q 'ksu_is_su_session_fd' kernel/supercall/dispatch.c
grep -A5 'KSU_IOCTL_GET_WRAPPER_FD' kernel/supercall/dispatch.c | grep -q 'allow_su_session = true'
grep -A5 'KSU_IOCTL_DISABLE_ESCAPE_TO_ROOT' kernel/supercall/dispatch.c | grep -q 'allow_su_session = true'
grep -A20 'ksu_handle_post_execveat_sucompat' kernel/feature/sucompat.c | grep -q 'ksu_install_su_fd'
grep -A40 'ksu_install_file_wrapper' kernel/infra/file_wrapper.c | grep -q 'override_creds(ksu_cred)'

echo '[+] Manager UAPI compatibility tests passed'
