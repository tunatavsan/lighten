# Architecture

Lighten is a Swift Package Manager project for macOS 26 and later. It has no Xcode project and has three targets:

- `Lighten` is the executable target and owns the SwiftUI application entry point. It declares no SwiftPM resources.
- `LightenKit` is the library target. It contains reusable application logic that can be exercised independently by `LightenKitTests`.
- `LightenKitTests` verifies the library and repository resource contracts.

The executable depends on `LightenKit`. `LightenKit` has no package dependencies, and the test target depends only on `LightenKit`.

The repository-level `Resources/` directory contains application-bundle inputs. `scripts/package_app.sh` copies the property list and privacy manifest, compiles `Localizable.xcstrings` into language-specific strings files, and assembles them in the application bundle. SwiftUI localization resolves those compiled strings through `Bundle.main` at runtime.

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

### Execution, journal, and undo

`ActionExecutor` serializes a plan under the journal's exclusive mutation lease. The lease uses a nonblocking filesystem lock across journal instances and processes. An existing plan ID cannot be executed again; a fresh user action requires a fresh plan. The executor appends its complete intent and requires a successful flush and `fsync` before calling the injected Trash service. Newly created journal directories and their parents are synced, and journal and lock files must be regular files owned by the current user. Invalid journal event sequences remain visible as issues and block further mutation. `ActionGuard` rechecks the selected root, its ancestors, and every descendant immediately before each move, including after an injectable final hook. Selected items require full metadata equality; directory ancestors compare stable volume, inode, kind, and flags because moving a sibling can legitimately change their timestamps and size. A changed or newly protected child, unreadable item, symlink, mount, dataless item, or package boundary skips the selected root. The `catalogDelete` value is reserved and always denied by this executor.

The application Trash adapter calls Foundation off the main actor. The journal records the actual returned Trash path and its moved identity; a failed applied append or an unobservable moved result is uncertain, not a successful or failed move. Each plan item has a result, including `notAttempted` for untouched items after an early stop. `ActionHistory` takes the same lease when reconciling or undoing, so it cannot present an in-flight state as final. It rebuilds state from durable records after restart and leaves an intent unresolved when the source is gone and the returned Trash path was never recorded. It never enumerates or empties the system Trash. Undo first appends a durable undo intent, checks the returned item and original parent, and re-resolves the parent path after the journal await. It then uses an exclusive no-follow rename into the original name. A collision preserves both items. An append failure after the rename leaves an observable undo intent for reconciliation.

Foundation Trash accepts a path, so validation and the move are not an atomic identity-bound operation. A concurrent change in that final window remains a limit of this implementation; it must not be described as race-proof. The volume UUID and device number are rechecked before a move. Journaled device/inode identity may become unusable after a reboot or remount; reconciliation then remains uncertain and undo fails closed rather than guessing. Trash bytes are pending, not reclaimed disk space. Only items moved by Lighten appear in its action history.
