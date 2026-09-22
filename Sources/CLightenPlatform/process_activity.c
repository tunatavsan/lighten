#include "CLightenPlatform.h"
#include <errno.h>
#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <unistd.h>

int lighten_process_name_veto(const char *name, int category) {
  if (!name || (category != 0 && category != 1)) return -1;
  if (category == 0) {
    return strncasecmp(name, "pip", 3) == 0 || strncasecmp(name, "python", 6) == 0 ||
           strcasecmp(name, "uv") == 0;
  }
  return strcasecmp(name, "brew") == 0 || strcasecmp(name, "curl") == 0 ||
         strcasecmp(name, "wget") == 0 || strcasecmp(name, "ruby") == 0 ||
         strcasecmp(name, "sh") == 0 || strcasecmp(name, "bash") == 0 ||
         strcasecmp(name, "zsh") == 0;
}

int lighten_process_activity(int category) {
  if (category != 0 && category != 1) return -1;
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_UID, (int)geteuid()};
  for (int attempt = 0; attempt < 3; attempt++) {
    size_t bytes = 0;
    if (sysctl(mib, 4, NULL, &bytes, NULL, 0) != 0) return -1;
    if (bytes > 16 * 1024 * 1024) return -1;
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
    if (actual % sizeof(struct kinfo_proc) != 0) {
      free(list);
      return -1;
    }
    int result = 0;
    int retry = 0;
    for (size_t i = 0; i < actual / sizeof(struct kinfo_proc); i++) {
      pid_t pid = list[i].kp_proc.p_pid;
      struct proc_bsdinfo info;
      int read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
      if (read != sizeof(info)) {
        if (errno == ESRCH) { retry = 1; break; }
        result = -1;
        break;
      }
      if (info.pbi_uid != geteuid() ||
          info.pbi_start_tvsec != (uint64_t)list[i].kp_proc.p_un.__p_starttime.tv_sec ||
          info.pbi_start_tvusec != (uint64_t)list[i].kp_proc.p_un.__p_starttime.tv_usec) {
        retry = 1;
        break;
      }
      char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
      char name[PROC_PIDPATHINFO_MAXSIZE] = {0};
      int path_length = proc_pidpath(pid, path, sizeof(path));
      if (path_length > 0 && (size_t)path_length < sizeof(path)) {
        const char *base = strrchr(path, '/');
        const char *chosen = base ? base + 1 : path;
        if (!*chosen) { result = -1; break; }
        strncpy(name, chosen, sizeof(name) - 1);
      } else {
        int length = proc_name(pid, name, sizeof(name));
        // BSD command names can truncate at MAXCOMLEN. A shorter name is
        // usable evidence; a full-width one cannot exclude a relevant tool.
        if (length <= 0 || length >= MAXCOMLEN - 1) {
          result = -1;
          break;
        }
      }
      if (lighten_process_name_veto(name, category) == 1) {
        result = 1;
        break;
      }
    }
    free(list);
    if (retry) continue;
    return result;
  }
  return -1;
}
