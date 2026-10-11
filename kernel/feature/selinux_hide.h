#ifndef __KSU_H_SELINUX_HIDE
#define __KSU_H_SELINUX_HIDE

#include <linux/sched.h>
#include <linux/types.h>
#include <linux/version.h>

void ksu_selinux_hide_init();
void ksu_selinux_hide_exit();
void ksu_selinux_hide_drop_backup_if_unused();
void ksu_selinux_hide_handle_second_stage();
void ksu_selinux_hide_handle_post_fs_data();

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
#ifdef KSU_COMPAT_SETPROCATTR_USE_NEW_PROTOTYPE
typedef int (*setprocattr_fn)(const char *name, void *value, size_t size);
int ksu_handle_selinux_setprocattr(const char *name, void *value, size_t size);
#else
typedef int (*setprocattr_fn)(struct task_struct *p, char *name, void *value, size_t size);
int ksu_handle_selinux_setprocattr(struct task_struct *p, char *name, void *value, size_t size);
#endif
#endif

#endif
