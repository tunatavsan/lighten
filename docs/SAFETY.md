# Safety

These rules protect sensitive locations and prevent changes to application contents. Generic cleanup suggestions, app-related cleanup, and AI recommendations continue to refuse every protected rule.

Space permits explicitly selected Trash-only items after checking their complete current inventory. Device backups are selectable only as a whole `MobileSync/Backup/<device identifier>` folder. Virtual machines and container images require their related apps to be closed and no observed current-user process to hold a file or working directory beneath the selected root. Sparse images must be detached; an unavailable attachment check refuses the item. These permissions do not authorize permanent deletion.

Moving a whole candidate or application package to the Trash is not architecture thinning or language removal: its contents move together and can be restored together. Space Trash plans may include intact nested application packages, localization resources, and application executables; every included application must be closed. Selecting part of a package remains forbidden. Descendant sockets and FIFOs move only as leaves; device nodes and special-file operation roots remain forbidden.

Catalog Trash plans may include descendants covered by the architecture-slice and localization rules; only regenerable build-output candidates may also include debug symbols. These exceptions do not authorize permanent deletion, which retains the strict protected-content rules.

This file is generated from `NeverRule.all`. Edit the rules, then regenerate this document with `LIGHTEN_UPDATE_SAFETY_DOC=1 swift test`.

## Always protected

| Protected pattern | Reason | Evidence |
| --- | --- | --- |
| `/System/**` | System files are required by macOS and must never be offered for cleanup. | macOS protects this tree with System Integrity Protection. |
| `/System/Library/dyld/**` | The dynamic linker cache is required to launch macOS and its applications. | The cache is managed by macOS. |
| `/**/*.lproj/**` | Localization bundles contain the language resources shipped with applications. | — |
| `/**/*.app/Contents/MacOS/**` | Removing architecture slices can invalidate signatures and make universal applications unusable. | — |
| `~/**/*.photoslibrary/**` | A Photos library contains irreplaceable originals, edits, and database state. | — |
| `/Volumes/**/*.photoslibrary/**` | A Photos library contains irreplaceable originals, edits, and database state. | — |
| `~/Library/Mail/**` | Mail data and attachments may be the only local copies of user content. | — |
| `~/Library/Messages/**` | Messages data and attachments may be the only local copies of user content. | — |
| `~/Library/Mobile Documents/**` | Deleting iCloud Drive content locally can also delete its cloud copy. | — |
| `~/Library/CloudStorage/**` | Deleting File Provider content locally can also delete its cloud copy. | — |
| `~/Library/Containers/*/Data/Documents/**` | Application container Documents folders contain user-created data. | — |
| `~/Library/Group Containers/**` | Group containers hold shared application state and user data. | — |
| `~/Library/Keychains/**` | Keychains contain credentials, certificates, and encryption keys. | — |
| `~/.ssh/**` | SSH configuration and private keys are security credentials that may be irreplaceable. | — |
| `~/Library/Developer/CoreSimulator/Volumes/**` | Mounted simulator runtime volumes are managed by CoreSimulator and must not be edited directly. | — |

## Explicit selection, Trash only

| Protected pattern | Reason | Evidence |
| --- | --- | --- |
| `~/Library/Developer/Xcode/Archives/**` | Xcode archives and their debug symbols may be required for distribution and crash analysis. | — |
| `~/**/*.dSYM/**` | Debug symbol bundles may be required to symbolicate crash reports. | — |
| `~/Library/Containers/com.docker.docker/Data/vms/**/Docker.raw` | Docker disk images contain container volumes, images, and other user data. | — |
| `~/Library/Group Containers/*.orbstack/data.img` | OrbStack disk images contain virtual machines, containers, and volumes. | — |
| `~/**/*.pvm/**` | Parallels virtual machine bundles contain complete guest systems and user data. | — |
| `~/**/*.utm/**` | UTM virtual machine bundles contain complete guest systems and user data. | — |
| `~/**/*.vmwarevm/**` | VMware virtual machine bundles contain complete guest systems and user data. | — |
| `~/**/*.sparsebundle/**` | Sparse bundles may contain encrypted disks, backups, virtual machines, or other user data. | — |
| `~/**/*.sparseimage` | Sparse disk images may contain encrypted disks, backups, virtual machines, or other user data. | — |
| `~/.m2/repository/**` | The Maven local repository may contain locally built artifacts that cannot be downloaded again. | — |
| `~/Library/Application Support/MobileSync/**` | iPhone and iPad backups may be the only available copies of device data. | Manage these backups in Finder. |
