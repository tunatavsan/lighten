# Architecture

Lighten is a Swift Package Manager project for macOS 26 and later. It has no Xcode project and has five targets:

- `Lighten` is the executable target and owns the SwiftUI application entry point. It declares no SwiftPM resources.
- `LightenKit` is the library target. It contains reusable application logic and a bundled Clean catalog that can be exercised independently by `LightenKitTests`.
- `CLightenPlatform` provides a narrow current-user process metadata check to the app without reading process arguments or environment.
- `LightenKitTests` verifies the library and repository resource contracts.
- `LightenAppTests` verifies application state and confirmation flow.

The executable depends on `LightenKit` and `CLightenPlatform`. `LightenKit` has no package dependencies.

The repository-level `Resources/` directory contains application-bundle inputs. `scripts/package_app.sh` copies the property list, privacy manifest, and SwiftPM resource bundle, compiles `Localizable.xcstrings` into language-specific strings files, and assembles them in the application bundle. SwiftUI localization resolves those compiled strings through `Bundle.main` at runtime. A packaged app loads its Clean manifest only from `Contents/Resources/Lighten_LightenKit.bundle`; missing resources fail closed.

## Contracts

### NeverRule

`NeverRule` defines a protected cleanup pattern with a stable identifier, a user-facing reason, and optional supporting evidence. `NeverRule.all` is the canonical ordered collection of locations and operations that Lighten must never offer for cleanup. Consumers must preserve these protections before presenting cleanup choices. `PathPattern` matches absolute path components: `*` matches characters within one component; `**` matches zero or more complete components. Consequently, `X/**` includes `X` itself. A leading `~` expands to an injected home directory so tests and future scanners use the same rule set without depending on the host user's home.

### Bundle identity and version

`LightenIdentity.bundleIdentifier` is the Swift identity source. The source `Info.plist` identifier must match it; tests and `scripts/package_app.sh` enforce that equality before signing. The package script signs with the value from the validated plist and checks the signed result. `LightenVersion` owns marketing and build versions; the source plist keeps placeholders that the package script replaces.

### SafetyDocument

`SafetyDocument.markdown(rules:)` renders a set of `NeverRule` values as the checked-in safety reference at `docs/SAFETY.md`. Its default input is `NeverRule.all`; `SafetyDocumentTests` verifies that the generated output and checked-in document stay identical.

### Scan and action values

`ScanService` takes an explicit directory root and emits progress plus an immutable `ScanSnapshot`. The scanner uses descriptor-relative, no-follow metadata access and does not read file contents. It stops at protected locations, symlinks, volume boundaries, dataless items, and packages. Unknown or unreadable entries make ancestor totals partial; a known lower bound is never presented as a complete total. The injectable `FileAttributeSource` returns only `Sendable` metadata values. Snapshots carry both the mount-time device number and the filesystem volume UUID. If the UUID is unavailable, the scan remains visible but cannot produce an action. Direct scans run off the main actor and propagate caller cancellation. A scan may start at `/`, but that root cannot be selected for an action.

`PlanService` turns explicit snapshot entry IDs into immutable `ActionPlan` items with the selected root, every observed descendant, and ancestor identities. Parent and child selections collapse to one root. A partial node, package interior, protected item, or broad filesystem root cannot become a plan. `makePlanAsync` keeps planning work off the UI actor. A plan is an observation for later validation, never authority conferred by a path string.

`ScanService.scanImmediateChild` observes a single named child and its complete safe subtree beneath a real parent. The parent remains partial and unselectable; sibling contents are not traversed. This permits a related-data candidate to be planned without scanning all of `~/Library/Caches` or `~/Library/Preferences`.

Space indexes immutable scan entries into a descending folder list and a deterministic area-proportional rectangle treemap. Disk used/free comes from a separate volume measurement, not the scan total. Selected Space items and Clean Trash candidates use the same action presentation, confirmation, executor, and history. Motion applies to state transitions and respects Reduce Motion.

### Execution, journal, and undo

`ActionExecutor` serializes a plan under the journal's exclusive mutation lease. The lease uses a nonblocking filesystem lock across journal instances and processes. An existing plan ID cannot be executed again; a fresh user action requires a fresh plan. The executor appends its complete intent and requires a successful flush and `fsync` before any mutation. Newly created journal directories and their parents are synced, and journal and lock files must be regular files owned by the current user. Invalid journal event sequences remain visible as issues and block further mutation. `ActionGuard` rechecks the selected root, its ancestors, and every descendant immediately before each move, including after an injectable final hook. Selected items require full metadata equality; directory ancestors compare stable volume, inode, kind, and flags because moving a sibling can legitimately change their timestamps and size. A changed or newly protected child, unreadable item, symlink, mount, dataless item, or package boundary skips the selected root.

Only three exact bundled cache areas can receive catalog proof: pip HTTP-v2, pip wheels, and Homebrew downloads. The catalog never grants access to its root or an arbitrary configured path. Both Clean Trash and permanent plans carry method-bound proof and recheck current-user tool activity at the final guard. Permanent plans additionally require a plan-bound irreversible confirmation. The executor independently checks the bundled manifest, per-item proof, full inventory, volume, and protection rules. It deletes each verified leaf through a pinned parent descriptor with no-follow `unlinkat`, then journals the actual irreversible count and known logical bytes. A changed remaining child or ancestor stops the action as partial. An unknown activity state blocks both Clean methods. Related items use Trash or remain report-only.

Related app data uses an exact installed bundle identifier plus a standard matching cache or preferences domain to record a bounded metadata receipt. App discovery covers `/Applications` and `~/Applications`; unreadable or incomplete inventory never proves absence. A later complete inventory can identify the same stable object as previously related to an owner absent from those locations, while explaining that the app may exist elsewhere. Receipts are limited to verified metadata and stored with no-follow, bounded, owner-only file access; they do not authorize an action alone. A fresh complete scan, receipt validation, current owner check, running-app veto, Guard, and explicit Trash confirmation remain necessary. Shared Group Containers are report-only and not traversed.

The application Trash adapter calls Foundation off the main actor. The journal records the actual returned Trash path and its moved identity; a failed applied append or an unobservable moved result is uncertain, not a successful or failed move. Trash recovery uses stable device, inode, type, volume, birth time, modification time, size, link count, and flags, allowing ctime to change after a move. Older records without that proof remain uncertain. Each plan item has a result, including `notAttempted` for untouched items after an early stop. `ActionHistory` takes the same lease when reconciling or undoing, so it cannot present an in-flight state as final. It rebuilds state from durable records after restart and leaves an intent unresolved when the source is gone and the returned Trash path was never recorded. It never enumerates or empties the system Trash. Undo first appends a durable undo intent, checks the returned item and original parent, and re-resolves the parent path after the journal await. It then uses an exclusive no-follow rename into the original name. A collision preserves both items. An append failure after the rename leaves an observable undo intent for reconciliation. Permanent catalog history shows irreversible or partial outcomes and has no undo.

Foundation Trash accepts a path, so validation and the move are not an atomic identity-bound operation. A concurrent change in that final window remains a limit of this implementation; it must not be described as race-proof. The volume UUID and device number are rechecked before a move. Journaled device/inode identity may become unusable after a reboot or remount; reconciliation then remains uncertain and undo fails closed rather than guessing. Trash bytes are pending, not reclaimed disk space. Only items moved by Lighten appear in its action history.
