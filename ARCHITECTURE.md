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
