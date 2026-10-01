#include "CLightenPlatform.h"
#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <unistd.h>

static int application_executable(const char *path) {
  // Syntax selects leads only. Swift independently binds each executable to
  // a fresh native physical package and valid bundle identifier.
  const char *part = path;
  while ((part = strchr(part, '/')) != NULL) {
    part++;
    const char *end = strchr(part, '/');
    if (!end) break;
    size_t size = (size_t)(end - part);
    if (size > 4 && strncasecmp(end - 4, ".app", 4) == 0) return 1;
  }
  return 0;
}

static int append_path(LightenApplicationDataPath *records, int32_t capacity,
                       int32_t *count, pid_t pid, const struct proc_bsdinfo *info,
                       const char *executable, const struct vnode_info_path *vnode, int is_cwd) {
  const char *path = vnode->vip_path;
  if (path[0] != '/' || strnlen(path, sizeof(vnode->vip_path)) >= sizeof(vnode->vip_path)) return 1;
  if (*count >= capacity) return 0;
  LightenApplicationDataPath *record = &records[(*count)++];
  memset(record, 0, sizeof(*record));
  record->pid = pid;
  record->uid = info->pbi_uid;
  record->start_seconds = info->pbi_start_tvsec;
  record->start_microseconds = info->pbi_start_tvusec;
  record->data_device = vnode->vip_vi.vi_stat.vst_dev;
  record->data_inode = vnode->vip_vi.vi_stat.vst_ino;
  record->is_cwd = is_cwd;
  strlcpy(record->executable_path, executable, sizeof(record->executable_path));
  strlcpy(record->data_path, path, sizeof(record->data_path));
  return 1;
}

int lighten_read_application_data_paths(LightenApplicationDataPath *records,
                                       int32_t capacity, int32_t *count) {
  if (!records || !count || capacity <= 0 || capacity > 4096) return -1;
  *count = 0;
  int required = proc_listpids(PROC_UID_ONLY, geteuid(), NULL, 0);
  if (required <= 0 || required > 1024 * 1024) return -1;
  size_t bytes = (size_t)required + 64 * sizeof(pid_t);
  pid_t *pids = calloc(1, bytes);
  if (!pids) return -1;
  int actual = proc_listpids(PROC_UID_ONLY, geteuid(), pids, (int)bytes);
  if (actual <= 0 || (size_t)actual >= bytes || actual % sizeof(pid_t) != 0) {
    free(pids);
    return -1;
  }
  int complete = 1;
  for (size_t index = 0; index < (size_t)actual / sizeof(pid_t); index++) {
    pid_t pid = pids[index];
    if (pid <= 0) continue;
    struct proc_bsdinfo before, after;
    memset(&before, 0, sizeof(before));
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &before, sizeof(before)) != sizeof(before)) continue;
    if (before.pbi_uid != geteuid()) continue;
    char executable[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, executable, sizeof(executable)) <= 0) continue;
    if (!application_executable(executable)) continue;
    int32_t begin = *count;
    struct proc_vnodepathinfo cwd;
    memset(&cwd, 0, sizeof(cwd));
    if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &cwd, sizeof(cwd)) == sizeof(cwd)) {
      if (!append_path(records, capacity, count, pid, &before, executable, &cwd.pvi_cdir, 1)) complete = 0;
    } else { complete = 0; }
    int fd_bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (fd_bytes < 0 || fd_bytes > 16 * 1024 * 1024) { complete = 0; }
    else if (fd_bytes > 0) {
      size_t fd_capacity = (size_t)fd_bytes + 64 * sizeof(struct proc_fdinfo);
      struct proc_fdinfo *fds = malloc(fd_capacity);
      int got = fds ? proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, (int)fd_capacity) : -1;
      if (got < 0 || (size_t)got >= fd_capacity || got % sizeof(struct proc_fdinfo) != 0) { complete = 0; }
      else {
        for (size_t fd_index = 0; fd_index < (size_t)got / sizeof(struct proc_fdinfo); fd_index++) {
          if (fds[fd_index].proc_fdtype != PROX_FDTYPE_VNODE) continue;
          struct vnode_fdinfowithpath info;
          memset(&info, 0, sizeof(info));
          if (proc_pidfdinfo(pid, fds[fd_index].proc_fd, PROC_PIDFDVNODEPATHINFO, &info, sizeof(info)) != sizeof(info)) {
            complete = 0;
            continue;
          }
          if (!append_path(records, capacity, count, pid, &before, executable, &info.pvip, 0)) complete = 0;
        }
      }
      free(fds);
    }
    char current_executable[PROC_PIDPATHINFO_MAXSIZE] = {0};
    memset(&after, 0, sizeof(after));
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, sizeof(after)) != sizeof(after)
        || proc_pidpath(pid, current_executable, sizeof(current_executable)) <= 0
        || before.pbi_uid != after.pbi_uid || before.pbi_start_tvsec != after.pbi_start_tvsec
        || before.pbi_start_tvusec != after.pbi_start_tvusec
        || strcmp(executable, current_executable) != 0) {
      *count = begin;
      complete = 0;
    }
    if (*count == capacity) { complete = 0; break; }
  }
  free(pids);
  return complete ? 0 : -1;
}
