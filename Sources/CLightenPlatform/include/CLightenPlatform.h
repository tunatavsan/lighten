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

enum {
  LIGHTEN_OBJ_REGULAR = 1,
  LIGHTEN_OBJ_DIRECTORY = 2,
  LIGHTEN_OBJ_SYMLINK = 3,
  LIGHTEN_OBJ_OTHER = 4,
};

enum {
  LIGHTEN_HAS_DEVICE = 1u << 0,
  LIGHTEN_HAS_KIND = 1u << 1,
  LIGHTEN_HAS_FLAGS = 1u << 2,
  LIGHTEN_HAS_FILE_ID = 1u << 3,
  LIGHTEN_HAS_LINK_COUNT = 1u << 4,
  LIGHTEN_HAS_LOGICAL = 1u << 5,
  LIGHTEN_HAS_ALLOCATED = 1u << 6,
};

// One directory entry parsed from a getattrlistbulk buffer. The name bytes stay
// in the caller's buffer at name_offset (without the terminating NUL).
typedef struct {
  uint64_t file_id;
  int64_t logical;
  int64_t allocated;
  uint32_t device;
  uint32_t flags;
  uint32_t link_count;
  uint32_t kind;
  int32_t error;
  uint32_t returned;
  uint32_t name_offset;
  uint32_t name_length;
} LightenDirEntry;

// Metadata only; never opens entries. >0: parsed entries, 0: end, -1: errno.
int lighten_bulk_read(int dirfd, void *buffer, size_t size, LightenDirEntry *out, int capacity);
// Space used by the volume containing path (APFS reports per-volume usage).
int lighten_volume_space_used(const char *path, int64_t *used_bytes);

#endif
