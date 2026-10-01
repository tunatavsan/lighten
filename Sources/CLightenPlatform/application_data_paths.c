#include "CLightenPlatform.h"
#include <errno.h>
#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <time.h>
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

static uint64_t monotonic_milliseconds(void) {
  struct timespec time;
  if (clock_gettime(CLOCK_MONOTONIC, &time) != 0) return 0;
  return (uint64_t)time.tv_sec * 1000 + (uint64_t)time.tv_nsec / 1000000;
}

struct census_buffer {
  LightenApplicationDataPath *records;
  uint32_t count;
  size_t capacity;
  size_t maximum;
  uint64_t deadline;
  LightenApplicationDataCensus *census;
};

static int within_deadline(struct census_buffer *buffer) {
  uint64_t now = monotonic_milliseconds();
  if (!now || now >= buffer->deadline) {
    buffer->census->failure_flags |= LIGHTEN_CENSUS_TIME_LIMIT;
    return 0;
  }
  return 1;
}

static int append_path(struct census_buffer *buffer, pid_t pid, const struct proc_bsdinfo *info,
                       const char *executable, const struct vnode_info_path *vnode, int is_cwd) {
  const char *path = vnode->vip_path;
  if (path[0] != '/' || strnlen(path, sizeof(vnode->vip_path)) >= sizeof(vnode->vip_path)) {
    buffer->census->failure_flags |= LIGHTEN_CENSUS_UNAVAILABLE;
    return 0;
  }
  if (buffer->count == buffer->capacity) {
    size_t next = buffer->capacity ? buffer->capacity * 2 : 64;
    if (next > buffer->maximum) next = buffer->maximum;
    if (next <= buffer->capacity) {
      buffer->census->failure_flags |= LIGHTEN_CENSUS_MEMORY_LIMIT;
      return 0;
    }
    LightenApplicationDataPath *records = realloc(buffer->records, next * sizeof(*records));
    if (!records) {
      buffer->census->failure_flags |= LIGHTEN_CENSUS_MEMORY_LIMIT;
      return 0;
    }
    buffer->records = records;
    buffer->capacity = next;
  }
  LightenApplicationDataPath *record = &buffer->records[buffer->count++];
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

void lighten_free_application_data_paths(LightenApplicationDataPath *records) { free(records); }

int lighten_copy_application_data_paths(size_t maximum_bytes, uint32_t timeout_milliseconds,
                                       LightenApplicationDataPath **records, uint32_t *count,
                                       LightenApplicationDataCensus *census) {
  if (!records || !count || !census) return -1;
  *records = NULL;
  *count = 0;
  memset(census, 0, sizeof(*census));
  uint64_t started = monotonic_milliseconds();
  if (!started || timeout_milliseconds == 0 || timeout_milliseconds > 10000) {
    census->failure_flags = LIGHTEN_CENSUS_TIME_LIMIT;
    return -1;
  }
  if (maximum_bytes < sizeof(LightenApplicationDataPath) || maximum_bytes > 512ULL * 1024 * 1024) {
    census->failure_flags = LIGHTEN_CENSUS_MEMORY_LIMIT;
    return -1;
  }
  struct census_buffer buffer = {0};
  buffer.maximum = maximum_bytes / sizeof(LightenApplicationDataPath);
  buffer.deadline = started + timeout_milliseconds;
  buffer.census = census;
  pid_t *pids = NULL;
  int actual = -1;
  size_t bytes = 0;
  for (int attempt = 0; attempt < 4 && within_deadline(&buffer); attempt++) {
    int required = proc_listpids(PROC_UID_ONLY, geteuid(), NULL, 0);
    if (required <= 0 || required > 1024 * 1024) break;
    size_t needed = (size_t)required + 64 * sizeof(pid_t);
    if (needed <= bytes) needed = bytes * 2;
    if (needed > 1024 * 1024) break;
    pid_t *next = realloc(pids, needed);
    if (!next) { census->failure_flags |= LIGHTEN_CENSUS_MEMORY_LIMIT; break; }
    pids = next;
    bytes = needed;
    actual = proc_listpids(PROC_UID_ONLY, geteuid(), pids, (int)bytes);
    if (actual > 0 && (size_t)actual < bytes && actual % sizeof(pid_t) == 0) break;
    actual = -1;
  }
  if (actual <= 0) { census->failure_flags |= LIGHTEN_CENSUS_UNAVAILABLE; goto finished; }
  for (size_t index = 0; index < (size_t)actual / sizeof(pid_t); index++) {
    if (!within_deadline(&buffer)) break;
    pid_t pid = pids[index];
    if (pid <= 0) continue;
    census->processes_inspected++;
    struct proc_bsdinfo before, after;
    memset(&before, 0, sizeof(before));
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &before, sizeof(before)) != sizeof(before)) {
      census->failure_flags |= LIGHTEN_CENSUS_UNAVAILABLE;
      continue;
    }
    if (before.pbi_uid != geteuid()) { census->failure_flags |= LIGHTEN_CENSUS_PROCESS_CHANGED; continue; }
    char executable[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, executable, sizeof(executable)) <= 0) {
      census->failure_flags |= LIGHTEN_CENSUS_UNAVAILABLE;
      continue;
    }
    if (!application_executable(executable)) continue;
    census->application_processes++;
    uint32_t begin = buffer.count;
    struct proc_vnodepathinfo cwd;
    memset(&cwd, 0, sizeof(cwd));
    if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &cwd, sizeof(cwd)) == sizeof(cwd)) {
      append_path(&buffer, pid, &before, executable, &cwd.pvi_cdir, 1);
    } else { census->failure_flags |= LIGHTEN_CENSUS_UNAVAILABLE; }
    int required = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (required < 0 || required > 16 * 1024 * 1024) { census->failure_flags |= LIGHTEN_CENSUS_UNAVAILABLE; }
    else if (required > 0) {
      struct proc_fdinfo *fds = NULL;
      size_t fd_capacity = 0;
      int got = -1;
      for (int attempt = 0; attempt < 4 && within_deadline(&buffer); attempt++) {
        size_t needed = (size_t)required + 64 * sizeof(struct proc_fdinfo);
        if (needed <= fd_capacity) needed = fd_capacity * 2;
        if (needed > 16 * 1024 * 1024) break;
        struct proc_fdinfo *next = realloc(fds, needed);
        if (!next) { census->failure_flags |= LIGHTEN_CENSUS_MEMORY_LIMIT; break; }
        fds = next;
        fd_capacity = needed;
        got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, (int)fd_capacity);
        if (got >= 0 && (size_t)got < fd_capacity && got % sizeof(struct proc_fdinfo) == 0) break;
        got = -1;
      }
      if (got < 0) { census->failure_flags |= LIGHTEN_CENSUS_UNAVAILABLE; }
      else {
        for (size_t fd_index = 0; fd_index < (size_t)got / sizeof(struct proc_fdinfo); fd_index++) {
          if (!within_deadline(&buffer)) break;
          if (fds[fd_index].proc_fdtype != PROX_FDTYPE_VNODE) continue;
          census->descriptors_inspected++;
          struct vnode_fdinfowithpath info;
          memset(&info, 0, sizeof(info));
          if (proc_pidfdinfo(pid, fds[fd_index].proc_fd, PROC_PIDFDVNODEPATHINFO, &info, sizeof(info)) != sizeof(info)) {
            census->failure_flags |= LIGHTEN_CENSUS_UNAVAILABLE;
            continue;
          }
          append_path(&buffer, pid, &before, executable, &info.pvip, 0);
          if (census->failure_flags & LIGHTEN_CENSUS_MEMORY_LIMIT) break;
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
      buffer.count = begin;
      census->failure_flags |= LIGHTEN_CENSUS_PROCESS_CHANGED;
    }
    if (census->failure_flags & (LIGHTEN_CENSUS_MEMORY_LIMIT | LIGHTEN_CENSUS_TIME_LIMIT)) break;
  }
finished:
  free(pids);
  *records = buffer.records;
  *count = buffer.count;
  census->elapsed_milliseconds = monotonic_milliseconds() - started;
  return census->failure_flags == 0 ? 0 : -1;
}
