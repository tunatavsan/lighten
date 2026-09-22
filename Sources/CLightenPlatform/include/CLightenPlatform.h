#ifndef CLIGHTEN_PLATFORM_H
#define CLIGHTEN_PLATFORM_H

#include <stdint.h>

typedef struct {
  int32_t pid;
  uint64_t start_seconds;
  uint64_t start_microseconds;
  uint64_t resident_bytes;
  uint64_t user_ticks;
  uint64_t system_ticks;
  char name[64];
} LightenProcessSample;

// All three functions are read-only. A nonzero return means unavailable.
int lighten_read_pressure(int32_t *level, uint64_t *value_size);
int lighten_read_swap(uint64_t *used_bytes, uint64_t *total_bytes);
int lighten_read_processes(LightenProcessSample *samples, int32_t capacity,
                           int32_t *read_count, int32_t *unreadable_count,
                           int32_t *truncated, uint64_t *sample_ticks,
                           uint32_t *timebase_numer, uint32_t *timebase_denom);
const char *lighten_process_name(const LightenProcessSample *sample);

// 1: relevant process observed, 0: complete current-UID snapshot clear,
// -1: snapshot or classification incomplete. Never reads process arguments.
int lighten_process_activity(int category);
int lighten_process_name_veto(const char *name, int category);

#endif
