#ifndef LIGHTEN_APPLICATION_DATA_PATHS_H
#define LIGHTEN_APPLICATION_DATA_PATHS_H
#include <stddef.h>
#include <stdint.h>

typedef struct {
  int32_t pid;
  uint32_t uid;
  uint64_t start_seconds;
  uint64_t start_microseconds;
  uint64_t data_device;
  uint64_t data_inode;
  int32_t is_cwd;
  char executable_path[4096];
  char data_path[4096];
} LightenApplicationDataPath;

enum {
  LIGHTEN_CENSUS_UNAVAILABLE = 1,
  LIGHTEN_CENSUS_MEMORY_LIMIT = 2,
  LIGHTEN_CENSUS_TIME_LIMIT = 4,
  LIGHTEN_CENSUS_PROCESS_CHANGED = 8
};

typedef struct {
  uint32_t processes_inspected;
  uint32_t application_processes;
  uint64_t descriptors_inspected;
  uint32_t failure_flags;
  uint64_t elapsed_milliseconds;
} LightenApplicationDataCensus;

// One current-UID census with growing record and fd buffers, bounded by the
// caller's record-memory and runtime limits. PID/fd scratch space is at most
// 17 MiB. A limit or unreadable process always makes the census incomplete.
// Exited processes and closed descriptors report PROCESS_CHANGED so callers
// may replace the whole observation within their original deadline.
// Records are emitted only after PID, executable, UID and start time remain
// equal across its fd/cwd reads. Free records with the matching function.
// 0: complete; -1: incomplete (returned records remain observations).
int lighten_copy_application_data_paths(size_t maximum_bytes, uint32_t timeout_milliseconds,
                                       LightenApplicationDataPath **records, uint32_t *count,
                                       LightenApplicationDataCensus *census);
void lighten_free_application_data_paths(LightenApplicationDataPath *records);
#endif
