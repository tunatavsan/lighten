#include "CLightenPlatform.h"
#include <errno.h>
#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <unistd.h>

int lighten_path_is_under_root(const char *path, const char *root) {
  if (!path || !root || root[0] != '/') return 0;
  size_t length = strlen(root);
  if (length == 0 || (length > 1 && root[length - 1] == '/')) return 0;
  return strncmp(path, root, length) == 0 &&
         (path[length] == '\0' || path[length] == '/' || length == 1);
}

static int pid_uses_root(pid_t pid, const char *root) {
  struct proc_vnodepathinfo cwd;
  memset(&cwd, 0, sizeof(cwd));
  if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &cwd, sizeof(cwd)) == sizeof(cwd) &&
      lighten_path_is_under_root(cwd.pvi_cdir.vip_path, root)) return 1;

  int required = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
  if (required <= 0 || required > 16 * 1024 * 1024) return 0;
  // File descriptor tables can grow during observation. A bounded second query
  // avoids assuming that the first size is still current.
  for (int attempt = 0; attempt < 2; attempt++) {
    size_t capacity = (size_t)required + 64 * sizeof(struct proc_fdinfo);
    struct proc_fdinfo *fds = malloc(capacity);
    if (!fds) return 0;
    int actual = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, (int)capacity);
    if (actual <= 0 || actual % sizeof(struct proc_fdinfo) != 0) {
      free(fds);
      return 0;
    }
    int active = 0;
    for (size_t i = 0; i < (size_t)actual / sizeof(struct proc_fdinfo); i++) {
      if (fds[i].proc_fdtype != PROX_FDTYPE_VNODE) continue;
      struct vnode_fdinfowithpath info;
      memset(&info, 0, sizeof(info));
      if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDVNODEPATHINFO,
                         &info, sizeof(info)) == sizeof(info) &&
          lighten_path_is_under_root(info.pvip.vip_path, root)) {
        active = 1;
        break;
      }
    }
    free(fds);
    if (active) return 1;
    if ((size_t)actual < capacity) return 0;
    required = actual;
  }
  return 0;
}

int lighten_process_activity(const char *root, char *process_name, size_t name_capacity) {
  if (!root || root[0] != '/' || !process_name || name_capacity == 0) return -1;
  process_name[0] = '\0';
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_UID, (int)geteuid()};
  for (int attempt = 0; attempt < 3; attempt++) {
    size_t bytes = 0;
    if (sysctl(mib, 4, NULL, &bytes, NULL, 0) != 0 || bytes > 16 * 1024 * 1024) return -1;
    bytes += 64 * sizeof(struct kinfo_proc);
    struct kinfo_proc *list = malloc(bytes);
    if (!list) return -1;
    size_t actual = bytes;
    if (sysctl(mib, 4, list, &actual, NULL, 0) != 0) {
      int error = errno;
      free(list);
      if (error == ENOMEM) continue;
      return -1;
    }
    if (actual % sizeof(struct kinfo_proc) != 0) { free(list); return -1; }
    int active = 0;
    for (size_t i = 0; i < actual / sizeof(struct kinfo_proc); i++) {
      pid_t pid = list[i].kp_proc.p_pid;
      struct proc_bsdinfo before;
      if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &before, sizeof(before)) != sizeof(before) ||
          before.pbi_uid != geteuid()) continue;
      if (!pid_uses_root(pid, root)) continue;
      struct proc_bsdinfo after;
      if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, sizeof(after)) != sizeof(after) ||
          after.pbi_uid != before.pbi_uid || after.pbi_start_tvsec != before.pbi_start_tvsec ||
          after.pbi_start_tvusec != before.pbi_start_tvusec) continue;
      if (proc_name(pid, process_name, (uint32_t)name_capacity) <= 0) {
        const char *name = after.pbi_name[0] ? after.pbi_name : after.pbi_comm;
        strncpy(process_name, name, name_capacity - 1);
      }
      process_name[name_capacity - 1] = '\0';
      active = 1;
      break;
    }
    free(list);
    // Per-process races and inaccessible descriptors are not evidence of
    // activity. Unknown is reserved for an unreadable whole process table.
    return active;
  }
  return -1;
}
