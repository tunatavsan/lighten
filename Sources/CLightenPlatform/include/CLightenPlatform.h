#ifndef CLIGHTEN_PLATFORM_H
#define CLIGHTEN_PLATFORM_H

// 1: relevant process observed, 0: complete current-UID snapshot clear,
// -1: snapshot or classification incomplete. Never reads process arguments.
int lighten_process_activity(int category);
int lighten_process_name_veto(const char *name, int category);

#endif
