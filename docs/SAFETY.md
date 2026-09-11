# Safety

Lighten never offers the following locations or operations for cleanup. These protections are built into the app and apply before any cleanup choice is shown.

This file is generated from `NeverRule.all`. Edit the rules, then regenerate this document through the safety document test.

| Protected pattern | Reason | Evidence |
| --- | --- | --- |
| `/System/**` | System files are required by macOS and must never be offered for cleanup. | macOS protects this tree with System Integrity Protection. |
| `/System/Library/dyld/**` | The dynamic linker cache is required to launch macOS and its applications. | The cache is managed by macOS. |
| `/**/*.lproj/**` | Localization bundles contain the language resources shipped with applications. | — |
| `/**/*.app/Contents/MacOS/**` | Removing architecture slices can invalidate signatures and make universal applications unusable. | — |
| `~/Pictures/Photos Library.photoslibrary/**` | A Photos library contains irreplaceable originals, edits, and database state. | — |
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
| `~/Library/Mail/**` | Mail data and attachments may be the only local copies of user content. | — |
| `~/Library/Messages/**` | Messages data and attachments may be the only local copies of user content. | — |
| `~/Library/Mobile Documents/**` | Deleting iCloud Drive content locally can also delete its cloud copy. | — |
| `~/Library/CloudStorage/**` | Deleting File Provider content locally can also delete its cloud copy. | — |
| `~/Library/Application Support/MobileSync/**` | iPhone and iPad backups may be the only available copies of device data. | Manage these backups in Finder. |
| `~/Library/Containers/*/Data/Documents/**` | Application container Documents folders contain user-created data. | — |
| `~/Library/Group Containers/**` | Group containers hold shared application state and user data. | — |
| `~/Library/Keychains/**` | Keychains contain credentials, certificates, and encryption keys. | — |
| `~/.ssh/**` | SSH configuration and private keys are security credentials that may be irreplaceable. | — |
| `~/Library/Developer/CoreSimulator/Volumes/**` | Mounted simulator runtime volumes are managed by CoreSimulator and must not be edited directly. | — |
