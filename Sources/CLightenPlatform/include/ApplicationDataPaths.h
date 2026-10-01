#ifndef LIGHTEN_APPLICATION_DATA_PATHS_H
#define LIGHTEN_APPLICATION_DATA_PATHS_H
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

// One bounded current-UID census. Records are emitted only after the PID,
// executable, UID and start time remain equal across its fd/cwd reads.
// 0: complete census; -1: unavailable/truncated (records remain observations).
int lighten_read_application_data_paths(LightenApplicationDataPath *records,
                                       int32_t capacity, int32_t *count);
#endif
