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
#include <sys/stat.h>
#include <mach/vm_prot.h>
#include <time.h>
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

static uint64_t activity_milliseconds(void);

typedef struct {
  uint64_t device, inode, address, size;
  char path[MAXPATHLEN];
} MappedExecutable;

static int executable_mapping_snapshot(pid_t pid, uint32_t region_limit, uint64_t deadline,
                                       MappedExecutable **records, size_t *count,
                                       const MappedExecutable *expected, size_t expected_count) {
  uint64_t address = 0;
  size_t capacity = 0;
  *count = 0;
  for (uint32_t region = 0; region < region_limit; region++) {
    uint64_t observed = activity_milliseconds();
    if (!observed || observed >= deadline) return -1;
    struct proc_regionwithpathinfo info;
    memset(&info, 0, sizeof(info));
    errno = 0;
    if (proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &info, sizeof(info)) != sizeof(info)) {
      // EINVAL after a valid region means there is no next region. A census
      // with no executable vnode, or a different error, proves nothing.
      return errno == EINVAL && region > 0 && *count > 0 &&
             (!expected || *count == expected_count) ? 0 : -1;
    }
    if (info.prp_prinfo.pri_address < address ||
        info.prp_prinfo.pri_size > UINT64_MAX - info.prp_prinfo.pri_address) return -1;
    uint64_t next = info.prp_prinfo.pri_address + info.prp_prinfo.pri_size;
    if (next <= address) return -1;
    address = next;
    if (!(info.prp_prinfo.pri_protection & VM_PROT_EXECUTE)) continue;
    if (info.prp_vip.vip_path[0] != '/' ||
        strnlen(info.prp_vip.vip_path, sizeof(info.prp_vip.vip_path)) >= sizeof(info.prp_vip.vip_path) - 1 ||
        !S_ISREG(info.prp_vip.vip_vi.vi_stat.vst_mode)) return -1;
    MappedExecutable current = {
      .device = info.prp_vip.vip_vi.vi_stat.vst_dev,
      .inode = info.prp_vip.vip_vi.vi_stat.vst_ino,
      .address = info.prp_prinfo.pri_address,
      .size = info.prp_prinfo.pri_size,
    };
    memcpy(current.path, info.prp_vip.vip_path, sizeof(current.path));
    if (expected) {
      if (*count >= expected_count || current.device != expected[*count].device ||
          current.inode != expected[*count].inode || current.address != expected[*count].address ||
          current.size != expected[*count].size || strcmp(current.path, expected[*count].path) != 0) return -1;
    } else {
      if (*count == capacity) {
        size_t next_capacity = capacity ? capacity * 2 : 8;
        if (next_capacity > region_limit || next_capacity * sizeof(current) > 8 * 1024 * 1024) {
          next_capacity = region_limit;
        }
        MappedExecutable *grown = realloc(*records, next_capacity * sizeof(current));
        if (!grown) return -1;
        *records = grown;
        capacity = next_capacity;
      }
      (*records)[*count] = current;
    }
    (*count)++;
  }
  // Hitting the bound is incomplete even when every observed path is outside
  // the selected root. It cannot authorize a clear observation.
  return -1;
}

static int application_mapping_activity_until(int32_t pid, const char *root, uint32_t region_limit,
                                              uint64_t census_deadline) {
  if (pid <= 0 || !root || !lighten_path_is_under_root(root, root) ||
      region_limit == 0 || region_limit > 4096) return -1;
  uint64_t started = activity_milliseconds();
  if (!started) return -1;
  uint64_t deadline = started + 250;
  if (census_deadline && census_deadline < deadline) deadline = census_deadline;
  if (started >= deadline) return -1;
  struct kinfo_proc before, after;
  if (!read_process_identity(pid, &before) || before.kp_proc.p_stat == SZOMB) return -1;
  MappedExecutable *records = NULL;
  size_t count = 0, checked = 0;
  int first = executable_mapping_snapshot(pid, region_limit, deadline, &records, &count, NULL, 0);
  int second = first == 0 ?
    executable_mapping_snapshot(pid, region_limit, deadline, NULL, &checked, records, count) : -1;
  int result = -1;
  if (first == 0 && second == 0 && read_process_identity(pid, &after) &&
      after.kp_proc.p_stat != SZOMB &&
      after.kp_eproc.e_ucred.cr_uid == before.kp_eproc.e_ucred.cr_uid &&
      after.kp_proc.p_starttime.tv_sec == before.kp_proc.p_starttime.tv_sec &&
      after.kp_proc.p_starttime.tv_usec == before.kp_proc.p_starttime.tv_usec) {
    result = 0;
    for (size_t index = 0; index < count; index++) {
      size_t length = strlen(root);
      // A removed executable's old path may no longer be stat-able. Treat a
      // component-bounded case alias conservatively as activity as well.
      if (lighten_path_is_under_root(records[index].path, root) ||
          (strncasecmp(records[index].path, root, length) == 0 &&
           (records[index].path[length] == '\0' || records[index].path[length] == '/'))) {
        result = 1;
        break;
      }
    }
  }
  free(records);
  return result;
}

int lighten_application_mapping_activity(int32_t pid, const char *root, uint32_t region_limit) {
  return application_mapping_activity_until(pid, root, region_limit, 0);
}

static int pid_executes_root_until(pid_t pid, const char *root, uint64_t deadline) {
  char path[PROC_PIDPATHINFO_MAXSIZE];
  memset(path, 0, sizeof(path));
  errno = 0;
  if (proc_pidpath(pid, path, sizeof(path)) > 0) {
    if (lighten_path_is_under_root(path, root)) return 1;
    size_t length = strlen(root);
    if (length < sizeof(path) && strncasecmp(path, root, length) == 0 &&
        (path[length] == '\0' || path[length] == '/')) {
      char prefix[PROC_PIDPATHINFO_MAXSIZE];
      memcpy(prefix, path, length);
      prefix[length] = '\0';
      struct stat selected, observed;
      if (lstat(root, &selected) == 0 && lstat(prefix, &observed) == 0 &&
          selected.st_dev == observed.st_dev && selected.st_ino == observed.st_ino) return 1;
    }
    return 0;
  }
  int path_error = errno;
  if (path_error == ENOENT) {
    // An updater may unlink an executable while its process remains alive.
    // Recover bounded mapped-vnode evidence instead of ignoring the missing
    // path or making unrelated selections globally unavailable.
    int mapped = application_mapping_activity_until(pid, root, 4096, deadline);
    if (mapped >= 0) {
      char after_path[PROC_PIDPATHINFO_MAXSIZE] = {0};
      errno = 0;
      if (proc_pidpath(pid, after_path, sizeof(after_path)) <= 0 && errno == ENOENT) return mapped;
    }
  }
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

static int pid_executes_root(pid_t pid, const char *root) {
  return pid_executes_root_until(pid, root, 0);
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
  if (!root) return -1;
  char *physical = realpath(root, NULL);
  int result = observe_process_activity(physical ? physical : root, process_name, name_capacity, pid_executes_root, 0);
  free(physical);
  return result;
}

static uint64_t activity_milliseconds(void) {
  struct timespec value;
  if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return 0;
  return (uint64_t)value.tv_sec * 1000 + (uint64_t)value.tv_nsec / 1000000;
}

static int executable_vnode(pid_t pid, const char *path, uint64_t deadline,
                            uint64_t *device, uint64_t *inode) {
  struct stat file;
  if (lstat(path, &file) != 0 || !S_ISREG(file.st_mode)) return -1;
  uint64_t address = 0;
  for (unsigned int region = 0; region < 4096 && activity_milliseconds() < deadline; region++) {
    struct proc_regionwithpathinfo info;
    memset(&info, 0, sizeof(info));
    if (proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &info, sizeof(info)) != sizeof(info)) return -1;
    if (strnlen(info.prp_vip.vip_path, sizeof(info.prp_vip.vip_path)) >= sizeof(info.prp_vip.vip_path)) return -1;
    if ((info.prp_prinfo.pri_protection & VM_PROT_EXECUTE) && strcmp(info.prp_vip.vip_path, path) == 0) {
      if (info.prp_vip.vip_vi.vi_stat.vst_dev != (uint32_t)file.st_dev ||
          info.prp_vip.vip_vi.vi_stat.vst_ino != file.st_ino) return -1;
      *device = (uint32_t)file.st_dev;
      *inode = file.st_ino;
      return 0;
    }
    uint64_t next = info.prp_prinfo.pri_address + info.prp_prinfo.pri_size;
    if (next <= address || next < info.prp_prinfo.pri_address) return -1;
    address = next;
  }
  return -1;
}

static int capture_application_process(pid_t pid, LightenApplicationProcess *record, uint64_t deadline) {
  struct proc_bsdinfo before, after;
  memset(&before, 0, sizeof(before));
  memset(&after, 0, sizeof(after));
  if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &before, sizeof(before)) != sizeof(before) ||
      before.pbi_uid != geteuid()) return -1;
  memset(record, 0, sizeof(*record));
  if (proc_pidpath(pid, record->executable_path, sizeof(record->executable_path)) <= 0 ||
      strnlen(record->executable_path, sizeof(record->executable_path)) >= sizeof(record->executable_path) ||
      executable_vnode(pid, record->executable_path, deadline,
                       &record->executable_device, &record->executable_inode) != 0) return -1;
  char current[4096] = {0};
  if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, sizeof(after)) != sizeof(after) ||
      before.pbi_uid != after.pbi_uid || before.pbi_start_tvsec != after.pbi_start_tvsec ||
      before.pbi_start_tvusec != after.pbi_start_tvusec ||
      proc_pidpath(pid, current, sizeof(current)) <= 0 || strnlen(current, sizeof(current)) >= sizeof(current) ||
      strcmp(current, record->executable_path) != 0) return -1;
  record->pid = pid;
  record->uid = before.pbi_uid;
  record->start_seconds = before.pbi_start_tvsec;
  record->start_microseconds = before.pbi_start_tvusec;
  return 0;
}

static int copy_application_process_census(const char *root, LightenApplicationProcess **records,
                                          uint32_t *count, uint64_t deadline) {
  int mib[3] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
  struct kinfo_proc *list = NULL;
  size_t actual = 0;
  for (int attempt = 0; attempt < 3; attempt++) {
    uint64_t observed = activity_milliseconds();
    if (!observed || observed >= deadline) return -1;
    size_t bytes = 0;
    if (sysctl(mib, 3, NULL, &bytes, NULL, 0) != 0 || bytes > 16 * 1024 * 1024) return -1;
    bytes += 64 * sizeof(struct kinfo_proc);
    list = malloc(bytes);
    if (!list) return -1;
    actual = bytes;
    if (sysctl(mib, 3, list, &actual, NULL, 0) == 0) break;
    int error = errno;
    free(list);
    list = NULL;
    if (error != ENOMEM) return -1;
  }
  if (!list || actual % sizeof(*list) != 0) { free(list); return -1; }
  size_t capacity = 0;
  int result = 0;
  for (size_t index = 0; index < actual / sizeof(*list); index++) {
    uint64_t observed = activity_milliseconds();
    if (!observed || observed >= deadline) { result = -1; break; }
    pid_t pid = list[index].kp_proc.p_pid;
    if (pid <= 0 || list[index].kp_proc.p_stat == SZOMB) continue;
    int under = pid_executes_root_until(pid, root, deadline);
    if (under < 0) { result = -1; continue; }
    if (!under) continue;
    LightenApplicationProcess captured;
    if (capture_application_process(pid, &captured, deadline) != 0) { result = -1; continue; }
    if (*count == capacity) {
      size_t next = capacity ? capacity * 2 : 16;
      if (next * sizeof(captured) > 16 * 1024 * 1024) { result = -1; break; }
      LightenApplicationProcess *grown = realloc(*records, next * sizeof(captured));
      if (!grown) { result = -1; break; }
      *records = grown;
      capacity = next;
    }
    (*records)[(*count)++] = captured;
  }
  free(list);
  uint64_t finished = activity_milliseconds();
  if (!finished || finished >= deadline) return -1;
  return result;
}

int lighten_copy_application_processes(const char *root, LightenApplicationProcess **records, uint32_t *count) {
  if (!root || root[0] != '/' || !records || !count) return -1;
  *records = NULL;
  *count = 0;
  uint64_t started = activity_milliseconds();
  if (!started) return -1;
  uint64_t deadline = started + 3000;
  for (int attempt = 0; attempt < 3; attempt++) {
    // A process can exit or replace its image during enumeration. Only a new
    // complete census can recover from that race; partial records never merge.
    if (copy_application_process_census(root, records, count, deadline) == 0) return 0;
    free(*records);
    *records = NULL;
    *count = 0;
    uint64_t observed = activity_milliseconds();
    if (!observed || observed >= deadline || attempt == 2) break;
    uint64_t pause = deadline - observed < 25 ? deadline - observed : 25;
    struct timespec delay = { .tv_sec = 0, .tv_nsec = (long)pause * 1000000 };
    nanosleep(&delay, NULL);
  }
  return -1;
}

int lighten_current_user_application_evidence(uint32_t uid, int executable_evidence) {
  if (executable_evidence < -1 || executable_evidence > 1) return -1;
  if (uid == geteuid()) return executable_evidence;
  return executable_evidence == 1 ? 2 : 0;
}

static struct kinfo_proc *scoped_application_process_table(int current_uid, uint64_t deadline,
                                                          size_t *count) {
  int mib[4] = {CTL_KERN, KERN_PROC, current_uid ? KERN_PROC_UID : KERN_PROC_ALL, (int)geteuid()};
  unsigned int length = current_uid ? 4 : 3;
  *count = 0;
  for (int attempt = 0; attempt < 3; attempt++) {
    uint64_t now = activity_milliseconds();
    if (!now || now >= deadline) return NULL;
    size_t bytes = 0;
    if (sysctl(mib, length, NULL, &bytes, NULL, 0) != 0 || bytes > 16 * 1024 * 1024) return NULL;
    bytes += 64 * sizeof(struct kinfo_proc);
    struct kinfo_proc *list = malloc(bytes);
    if (!list) return NULL;
    size_t actual = bytes;
    if (sysctl(mib, length, list, &actual, NULL, 0) == 0) {
      if (actual % sizeof(*list) != 0) { free(list); return NULL; }
      *count = actual / sizeof(*list);
      if (current_uid) {
        int includes_observer = 0;
        for (size_t index = 0; index < *count; index++) {
          if (list[index].kp_proc.p_pid == getpid() &&
              list[index].kp_eproc.e_ucred.cr_uid == geteuid()) includes_observer = 1;
        }
        if (!includes_observer) { free(list); return NULL; }
      }
      return list;
    }
    int error = errno;
    free(list);
    if (error != ENOMEM) return NULL;
  }
  return NULL;
}

static int same_application_process_identity(const struct kinfo_proc *before,
                                             const struct kinfo_proc *after) {
  return before->kp_eproc.e_ucred.cr_uid == after->kp_eproc.e_ucred.cr_uid &&
    before->kp_proc.p_starttime.tv_sec == after->kp_proc.p_starttime.tv_sec &&
    before->kp_proc.p_starttime.tv_usec == after->kp_proc.p_starttime.tv_usec;
}

static int current_user_application_census(const char *root, LightenApplicationProcess **records,
                                          uint32_t *count, char *name, size_t capacity,
                                          uint64_t deadline) {
  size_t process_count = 0;
  struct kinfo_proc *list = scoped_application_process_table(1, deadline, &process_count);
  if (!list) return -1;
  int active = 0, incomplete = 0;
  size_t record_capacity = 0;
  for (size_t index = 0; index < process_count; index++) {
    uint64_t now = activity_milliseconds();
    if (!now || now >= deadline) { incomplete = 1; break; }
    struct kinfo_proc before = list[index], after;
    pid_t pid = before.kp_proc.p_pid;
    if (pid <= 0 || before.kp_proc.p_stat == SZOMB) continue;
    int evidence = pid_executes_root_until(pid, root, deadline);
    int evidence_error = errno;
    errno = 0;
    if (!read_process_identity(pid, &after)) {
      int identity_error = errno;
      if (kill(pid, 0) != 0 && errno == ESRCH) continue;
      if (!incomplete) name[0] = '\0';
      incomplete = 1;
      describe_unknown_process(name, capacity, &before, "process identity unavailable", identity_error);
      continue;
    }
    if (after.kp_proc.p_stat == SZOMB) continue;
    if (before.kp_eproc.e_ucred.cr_uid != geteuid() ||
        !same_application_process_identity(&before, &after)) {
      if (!incomplete) name[0] = '\0';
      incomplete = 1;
      describe_unknown_process(name, capacity, &before, "process identity changed during observation", -1);
      continue;
    }
    int scoped = lighten_current_user_application_evidence(after.kp_eproc.e_ucred.cr_uid, evidence);
    if (scoped < 0) {
      if (!incomplete) name[0] = '\0';
      incomplete = 1;
      describe_unknown_process(name, capacity, &after, "executable path unavailable", evidence_error);
      continue;
    }
    if (scoped == 0) continue;
    active = 1;
    if (name[0] == '\0') {
      strncpy(name, after.kp_proc.p_comm, capacity - 1);
      name[capacity - 1] = '\0';
    }
    if (!records) continue;
    LightenApplicationProcess captured;
    if (capture_application_process(pid, &captured, deadline) != 0) {
      if (!incomplete) name[0] = '\0';
      incomplete = 1;
      describe_unknown_process(name, capacity, &after, "executable signal binding unavailable", errno);
      continue;
    }
    if (*count == record_capacity) {
      size_t next = record_capacity ? record_capacity * 2 : 16;
      if (next * sizeof(captured) > 16 * 1024 * 1024) { incomplete = 1; break; }
      LightenApplicationProcess *grown = realloc(*records, next * sizeof(captured));
      if (!grown) { incomplete = 1; break; }
      *records = grown;
      record_capacity = next;
    }
    (*records)[(*count)++] = captured;
  }
  free(list);
  uint64_t finished = activity_milliseconds();
  return incomplete || !finished || finished >= deadline ? -1 : active;
}

static int observed_foreign_application(const char *root, char *name, size_t capacity, uint64_t deadline) {
  size_t count = 0;
  struct kinfo_proc *list = scoped_application_process_table(0, deadline, &count);
  if (!list) return 0;
  int administrative = 0;
  for (size_t index = 0; index < count; index++) {
    uint64_t now = activity_milliseconds();
    if (!now || now >= deadline) break;
    struct kinfo_proc before = list[index], after;
    if (before.kp_proc.p_pid <= 0 || before.kp_proc.p_stat == SZOMB ||
        before.kp_eproc.e_ucred.cr_uid == geteuid()) continue;
    int evidence = pid_executes_root_until(before.kp_proc.p_pid, root, deadline);
    if (lighten_current_user_application_evidence(before.kp_eproc.e_ucred.cr_uid, evidence) != 2) continue;
    if (!read_process_identity(before.kp_proc.p_pid, &after) || after.kp_proc.p_stat == SZOMB ||
        !same_application_process_identity(&before, &after)) continue;
    strncpy(name, after.kp_proc.p_comm, capacity - 1);
    name[capacity - 1] = '\0';
    administrative = 1;
    break;
  }
  free(list);
  return administrative;
}

static int scoped_current_user_application_observation(const char *root, LightenApplicationProcess **records,
                                                       uint32_t *count, char *name, size_t capacity,
                                                       int *requires_administrator) {
  if (!root || root[0] != '/' || !count || !name || capacity == 0 || !requires_administrator) return -1;
  if (records) *records = NULL;
  *count = 0;
  *requires_administrator = 0;
  name[0] = '\0';
  uint64_t started = activity_milliseconds();
  if (!started) return -1;
  uint64_t deadline = started + 3000;
  char *physical = realpath(root, NULL);
  const char *selected = physical ? physical : root;
  int result = -1;
  for (int attempt = 0; attempt < 3; attempt++) {
    name[0] = '\0';
    result = current_user_application_census(selected, records, count, name, capacity, deadline);
    if (result >= 0) break;
    if (records) { free(*records); *records = NULL; }
    *count = 0;
    uint64_t now = activity_milliseconds();
    if (!now || now >= deadline || attempt == 2) break;
    uint64_t pause = deadline - now < 25 ? deadline - now : 25;
    struct timespec delay = { .tv_sec = 0, .tv_nsec = (long)pause * 1000000 };
    nanosleep(&delay, NULL);
  }
  if (result >= 0) {
    *requires_administrator = observed_foreign_application(selected, name, capacity, deadline);
    if (*requires_administrator) result = 1;
  }
  free(physical);
  return result;
}

int lighten_current_user_application_activity(const char *root, char *process_name, size_t name_capacity,
                                               int *requires_administrator) {
  uint32_t count = 0;
  return scoped_current_user_application_observation(root, NULL, &count, process_name, name_capacity,
                                                    requires_administrator);
}

int lighten_copy_current_user_application_processes(const char *root, LightenApplicationProcess **records,
                                                   uint32_t *count, int *requires_administrator) {
  if (!records) return -1;
  char name[256] = {0};
  int result = scoped_current_user_application_observation(root, records, count, name, sizeof(name),
                                                         requires_administrator);
  return result < 0 ? -1 : 0;
}

void lighten_free_application_processes(LightenApplicationProcess *records) { free(records); }

int lighten_validate_application_process(const LightenApplicationProcess *record) {
  if (!record || record->uid != geteuid() || record->pid <= 0 || record->executable_path[0] != '/' ||
      strnlen(record->executable_path, sizeof(record->executable_path)) >= sizeof(record->executable_path)) return -1;
  LightenApplicationProcess current;
  if (capture_application_process(record->pid, &current, activity_milliseconds() + 1000) != 0 ||
      current.uid != record->uid || current.start_seconds != record->start_seconds ||
      current.start_microseconds != record->start_microseconds ||
      current.executable_device != record->executable_device || current.executable_inode != record->executable_inode ||
      strcmp(current.executable_path, record->executable_path) != 0) return -1;
  return 0;
}

int lighten_signal_application_process(const LightenApplicationProcess *record, int signal_number) {
  if (!record || (signal_number != SIGTERM && signal_number != SIGKILL)) return -1;
  if (kill(record->pid, 0) != 0 && errno == ESRCH) return 0;
  if (lighten_validate_application_process(record) != 0) return -1;
  return kill(record->pid, signal_number) == 0 || errno == ESRCH ? 0 : -1;
}
