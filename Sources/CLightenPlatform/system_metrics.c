#include "CLightenPlatform.h"
#include <errno.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <unistd.h>

int lighten_read_pressure(int32_t *level, uint64_t *value_size) {
  if (!level || !value_size) return -1;
  size_t length = sizeof(*level);
  int32_t value = 0;
  int result = sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &length, NULL, 0);
  *value_size = length;
  if (result != 0 || length != sizeof(value)) return -1;
  *level = value;
  return 0;
}

int lighten_read_swap(uint64_t *used_bytes, uint64_t *total_bytes) {
  if (!used_bytes || !total_bytes) return -1;
  struct xsw_usage value = {0};
  size_t length = sizeof(value);
  if (sysctlbyname("vm.swapusage", &value, &length, NULL, 0) != 0 ||
      length != sizeof(value)) return -1;
  *used_bytes = value.xsu_used;
  *total_bytes = value.xsu_total;
  return 0;
}

int lighten_read_processes(LightenProcessSample *samples, int32_t capacity,
                           int32_t *read_count, int32_t *unreadable_count,
                           int32_t *truncated, uint64_t *sample_ticks,
                           uint32_t *timebase_numer, uint32_t *timebase_denom) {
  if (!samples || capacity <= 0 || capacity > 4096 || !read_count ||
      !unreadable_count || !truncated || !sample_ticks || !timebase_numer ||
      !timebase_denom) return -1;
  *read_count = 0;
  *unreadable_count = 0;
  *truncated = 0;
  mach_timebase_info_data_t timebase;
  if (mach_timebase_info(&timebase) != KERN_SUCCESS ||
      timebase.denom == 0 || timebase.numer == 0) return -1;
  pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
  if (!pids) return -1;
  int bytes = proc_listpids(PROC_UID_ONLY, (uint32_t)geteuid(), pids,
                            capacity * (int32_t)sizeof(pid_t));
  if (bytes <= 0 || bytes % sizeof(pid_t) != 0) {
    free(pids);
    return -1;
  }
  int listed = bytes / (int)sizeof(pid_t);
  if (listed > capacity) {
    free(pids);
    return -1;
  }
  *truncated = listed >= capacity;
  *sample_ticks = mach_absolute_time();
  *timebase_numer = timebase.numer;
  *timebase_denom = timebase.denom;
  for (int i = 0; i < listed; i++) {
    if (pids[i] <= 0) continue;
    struct proc_taskallinfo info = {0};
    int size = proc_pidinfo(pids[i], PROC_PIDTASKALLINFO, 0, &info, sizeof(info));
    if (size != sizeof(info) || info.pbsd.pbi_uid != geteuid() ||
        !info.pbsd.pbi_comm[0]) {
      (*unreadable_count)++;
      continue;
    }
    LightenProcessSample *row = &samples[*read_count];
    row->pid = pids[i];
    row->start_seconds = info.pbsd.pbi_start_tvsec;
    row->start_microseconds = info.pbsd.pbi_start_tvusec;
    row->resident_bytes = info.ptinfo.pti_resident_size;
    row->user_ticks = info.ptinfo.pti_total_user;
    row->system_ticks = info.ptinfo.pti_total_system;
    size_t name_length = strnlen(info.pbsd.pbi_comm, sizeof(info.pbsd.pbi_comm));
    if (name_length >= sizeof(row->name)) name_length = sizeof(row->name) - 1;
    memcpy(row->name, info.pbsd.pbi_comm, name_length);
    row->name[name_length] = '\0';
    (*read_count)++;
  }
  free(pids);
  return 0;
}

const char *lighten_process_name(const LightenProcessSample *sample) {
  return sample ? sample->name : "";
}
