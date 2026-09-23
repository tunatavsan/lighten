#include "CLightenPlatform.h"
#include <errno.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/vnode.h>
#include <unistd.h>

// Attribute order in each packed record: length, returned set, error, name,
// devid, objtype, flags, fileid, then file attributes linkcount, totalsize,
// allocsize. Fields are only 4-byte aligned, so every read goes through memcpy.
static struct attrlist lighten_bulk_attributes(void) {
  struct attrlist list;
  memset(&list, 0, sizeof(list));
  list.bitmapcount = ATTR_BIT_MAP_COUNT;
  list.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_ERROR | ATTR_CMN_DEVID |
                    ATTR_CMN_OBJTYPE | ATTR_CMN_FLAGS | ATTR_CMN_FILEID;
  list.fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE;
  return list;
}

static uint32_t lighten_kind(fsobj_type_t type) {
  switch (type) {
  case VREG: return LIGHTEN_OBJ_REGULAR;
  case VDIR: return LIGHTEN_OBJ_DIRECTORY;
  case VLNK: return LIGHTEN_OBJ_SYMLINK;
  default: return LIGHTEN_OBJ_OTHER;
  }
}

int lighten_bulk_read(int dirfd, void *buffer, size_t size, LightenDirEntry *out, int capacity) {
  if (!buffer || !out || capacity <= 0 || size < 1024) {
    errno = EINVAL;
    return -1;
  }
  struct attrlist list = lighten_bulk_attributes();
  int count = getattrlistbulk(dirfd, &list, buffer, size, 0);
  if (count <= 0) return count;
  if (count > capacity) {
    errno = ENOBUFS;
    return -1;
  }
  const char *cursor = (const char *)buffer;
  const char *end = cursor + size;
  for (int index = 0; index < count; index++) {
    LightenDirEntry *entry = &out[index];
    memset(entry, 0, sizeof(*entry));
    uint32_t length = 0;
    // Bounds are compared as sizes so no pointer past the buffer is ever formed.
    size_t remaining = (size_t)(end - cursor);
    if (remaining < sizeof(length)) goto malformed;
    memcpy(&length, cursor, sizeof(length));
    if (length < sizeof(uint32_t) + sizeof(attribute_set_t) || length > remaining) goto malformed;
    const char *record_end = cursor + length;
    const char *field = cursor + sizeof(uint32_t);
    attribute_set_t returned;
    memcpy(&returned, field, sizeof(returned));
    field += sizeof(returned);

#define LIGHTEN_TAKE(target)                                                                       \
  do {                                                                                             \
    if ((size_t)(record_end - field) < sizeof(target)) goto malformed;                             \
    memcpy(&(target), field, sizeof(target));                                                      \
    field += sizeof(target);                                                                       \
  } while (0)

    if (returned.commonattr & ATTR_CMN_ERROR) {
      uint32_t error = 0;
      LIGHTEN_TAKE(error);
      entry->error = (int32_t)error;
    }
    if (returned.commonattr & ATTR_CMN_NAME) {
      const char *reference_start = field;
      attrreference_t reference;
      LIGHTEN_TAKE(reference);
      size_t available = (size_t)(record_end - reference_start);
      if (reference.attr_length == 0 || reference.attr_dataoffset < 0 ||
          (size_t)reference.attr_dataoffset > available ||
          (size_t)reference.attr_length > available - (size_t)reference.attr_dataoffset)
        goto malformed;
      const char *name = reference_start + reference.attr_dataoffset;
      entry->name_offset = (uint32_t)(name - (const char *)buffer);
      // attr_length includes the terminating NUL.
      entry->name_length = reference.attr_length - 1;
    } else {
      goto malformed;
    }
    if (returned.commonattr & ATTR_CMN_DEVID) {
      dev_t device = 0;
      LIGHTEN_TAKE(device);
      entry->device = (uint32_t)device;
      entry->returned |= LIGHTEN_HAS_DEVICE;
    }
    if (returned.commonattr & ATTR_CMN_OBJTYPE) {
      fsobj_type_t type = 0;
      LIGHTEN_TAKE(type);
      entry->kind = lighten_kind(type);
      entry->returned |= LIGHTEN_HAS_KIND;
    }
    if (returned.commonattr & ATTR_CMN_FLAGS) {
      uint32_t flags = 0;
      LIGHTEN_TAKE(flags);
      entry->flags = flags;
      entry->returned |= LIGHTEN_HAS_FLAGS;
    }
    if (returned.commonattr & ATTR_CMN_FILEID) {
      uint64_t file_id = 0;
      LIGHTEN_TAKE(file_id);
      entry->file_id = file_id;
      entry->returned |= LIGHTEN_HAS_FILE_ID;
    }
    if (returned.fileattr & ATTR_FILE_LINKCOUNT) {
      uint32_t links = 0;
      LIGHTEN_TAKE(links);
      entry->link_count = links;
      entry->returned |= LIGHTEN_HAS_LINK_COUNT;
    }
    if (returned.fileattr & ATTR_FILE_TOTALSIZE) {
      off_t logical = 0;
      LIGHTEN_TAKE(logical);
      entry->logical = (int64_t)logical;
      entry->returned |= LIGHTEN_HAS_LOGICAL;
    }
    if (returned.fileattr & ATTR_FILE_ALLOCSIZE) {
      off_t allocated = 0;
      LIGHTEN_TAKE(allocated);
      entry->allocated = (int64_t)allocated;
      entry->returned |= LIGHTEN_HAS_ALLOCATED;
    }
#undef LIGHTEN_TAKE
    cursor = record_end;
  }
  return count;

malformed:
  errno = EBADMSG;
  return -1;
}

int lighten_volume_space_used(const char *path, int64_t *used_bytes) {
  if (!path || !used_bytes) {
    errno = EINVAL;
    return -1;
  }
  struct attrlist list;
  memset(&list, 0, sizeof(list));
  list.bitmapcount = ATTR_BIT_MAP_COUNT;
  list.volattr = ATTR_VOL_INFO | ATTR_VOL_SPACEUSED;
  struct {
    uint32_t length;
    off_t used;
  } __attribute__((packed)) reply;
  memset(&reply, 0, sizeof(reply));
  if (getattrlist(path, &list, &reply, sizeof(reply), FSOPT_NOFOLLOW) != 0) return -1;
  if (reply.length < sizeof(reply)) {
    errno = ENOTSUP;
    return -1;
  }
  *used_bytes = (int64_t)reply.used;
  return 0;
}
