#include "CLightenPlatform.h"
#include <errno.h>
#include <libproc.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/proc.h>
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

static int read_process_identity(pid_t pid, struct kinfo_proc *details) {
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
  size_t size = sizeof(*details);
  memset(details, 0, size);
  return sysctl(mib, 4, details, &size, NULL, 0) == 0 && size == sizeof(*details) &&
         details->kp_proc.p_pid == pid;
}

static int pid_executes_root(pid_t pid, const char *root) {
  char path[PROC_PIDPATHINFO_MAXSIZE];
  memset(path, 0, sizeof(path));
  errno = 0;
  if (proc_pidpath(pid, path, sizeof(path)) > 0) {
    return lighten_path_is_under_root(path, root);
  }
  int path_error = errno;
  struct kinfo_proc details;
  if (read_process_identity(pid, &details)) {
    if (details.kp_proc.p_stat == SZOMB) return 0;
  } else if (kill(pid, 0) != 0 && errno == ESRCH) {
    return 0;
  }
  // A live process with an unavailable executable path cannot prove inactivity.
  errno = path_error;
  return -1;
}

static void describe_unknown_process(char *process_name, size_t name_capacity,
                                     const struct kinfo_proc *details,
                                     const char *reason, int observed_error) {
  if (process_name[0] != '\0') return;
  if (observed_error < 0) {
    snprintf(process_name, name_capacity, "%s (pid %d, uid %u): %s",
             details->kp_proc.p_comm[0] ? details->kp_proc.p_comm : "unnamed process",
             details->kp_proc.p_pid, details->kp_eproc.e_ucred.cr_uid, reason);
    return;
  }
  snprintf(process_name, name_capacity, "%s (pid %d, uid %u): %s; errno:%d",
           details->kp_proc.p_comm[0] ? details->kp_proc.p_comm : "unnamed process",
           details->kp_proc.p_pid, details->kp_eproc.e_ucred.cr_uid,
           reason, observed_error);
}

static int observe_process_activity(const char *root, char *process_name, size_t name_capacity,
                                    int (*uses_root)(pid_t, const char *), int current_uid_only) {
  if (!root || root[0] != '/' || !process_name || name_capacity == 0) return -1;
  process_name[0] = '\0';
  int mib[4] = {CTL_KERN, KERN_PROC, current_uid_only ? KERN_PROC_UID : KERN_PROC_ALL, (int)geteuid()};
  unsigned int mib_count = current_uid_only ? 4 : 3;
  for (int attempt = 0; attempt < 3; attempt++) {
    size_t bytes = 0;
    if (sysctl(mib, mib_count, NULL, &bytes, NULL, 0) != 0 || bytes > 16 * 1024 * 1024) return -1;
    bytes += 64 * sizeof(struct kinfo_proc);
    struct kinfo_proc *list = malloc(bytes);
    if (!list) return -1;
    size_t actual = bytes;
    if (sysctl(mib, mib_count, list, &actual, NULL, 0) != 0) {
      int error = errno;
      free(list);
      if (error == ENOMEM) continue;
      return -1;
    }
    if (actual % sizeof(struct kinfo_proc) != 0) { free(list); return -1; }
    int active = 0;
    int unknown = 0;
    for (size_t i = 0; i < actual / sizeof(struct kinfo_proc); i++) {
      pid_t pid = list[i].kp_proc.p_pid;
      if (pid <= 0) continue;
      if (!current_uid_only) {
        struct kinfo_proc before = list[i];
        if (before.kp_proc.p_stat == SZOMB) continue;
        int evidence = uses_root(pid, root);
        int evidence_error = errno;
        if (evidence == 0) continue;
        struct kinfo_proc after;
        errno = 0;
        if (!read_process_identity(pid, &after)) {
          int identity_error = errno;
          if (kill(pid, 0) == 0 || errno == EPERM) {
            unknown = 1;
            describe_unknown_process(process_name, name_capacity, &before,
                                     "process identity unavailable", identity_error);
          }
          continue;
        }
        if (after.kp_eproc.e_ucred.cr_uid != before.kp_eproc.e_ucred.cr_uid ||
            after.kp_proc.p_starttime.tv_sec != before.kp_proc.p_starttime.tv_sec ||
            after.kp_proc.p_starttime.tv_usec != before.kp_proc.p_starttime.tv_usec) {
          unknown = 1;
          describe_unknown_process(process_name, name_capacity, &before,
                                   "process identity changed during observation", -1);
          continue;
        }
        if (evidence < 0) {
          unknown = 1;
          describe_unknown_process(process_name, name_capacity, &after,
                                   "executable path unavailable", evidence_error);
          continue;
        }
        if (proc_name(pid, process_name, (uint32_t)name_capacity) <= 0) {
          strncpy(process_name, after.kp_proc.p_comm, name_capacity - 1);
        }
        process_name[name_capacity - 1] = '\0';
        active = 1;
        break;
      }
      struct proc_bsdinfo before;
      if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &before, sizeof(before)) != sizeof(before)) {
        continue;
      }
      if (before.pbi_uid != geteuid()) continue;
      int evidence = uses_root(pid, root);
      if (evidence == 0) continue;
      struct proc_bsdinfo after;
      if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, sizeof(after)) != sizeof(after)) {
        continue;
      }
      if (
          after.pbi_uid != before.pbi_uid || after.pbi_start_tvsec != before.pbi_start_tvsec ||
          after.pbi_start_tvusec != before.pbi_start_tvusec) continue;
      if (evidence < 0) { unknown = 1; continue; }
      if (proc_name(pid, process_name, (uint32_t)name_capacity) <= 0) {
        const char *name = after.pbi_name[0] ? after.pbi_name : after.pbi_comm;
        strncpy(process_name, name, name_capacity - 1);
      }
      process_name[name_capacity - 1] = '\0';
      active = 1;
      break;
    }
    free(list);
    // Descriptor races are not evidence of activity. The executable source
    // additionally reports an unreadable live executable path as unknown.
    return active ? 1 : unknown ? -1 : 0;
  }
  return -1;
}

int lighten_process_activity(const char *root, char *process_name, size_t name_capacity) {
  return observe_process_activity(root, process_name, name_capacity, pid_uses_root, 1);
}

int lighten_application_activity(const char *root, char *process_name, size_t name_capacity) {
  return observe_process_activity(root, process_name, name_capacity, pid_executes_root, 0);
}
