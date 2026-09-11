# Architecture

Lighten is a Swift Package Manager project for macOS 26 and later. It has no Xcode project and is split into two targets:

- `Lighten` is the executable target and owns the SwiftUI application entry point. It declares no SwiftPM resources.
- `LightenKit` is the library target. It contains reusable application logic that can be exercised independently by `LightenKitTests`.

The executable depends on `LightenKit`. `LightenKit` has no package dependencies, and the test target depends only on `LightenKit`.

The repository-level `Resources/` directory contains application-bundle inputs. `scripts/package_app.sh` copies the property list and privacy manifest, compiles `Localizable.xcstrings` into language-specific strings files, and assembles them in the application bundle. SwiftUI localization resolves those compiled strings through `Bundle.main` at runtime.

## Contracts

### NeverRule

`NeverRule` defines a protected cleanup pattern with a stable identifier, a user-facing reason, and optional supporting evidence. `NeverRule.all` is the canonical ordered collection of locations and operations that Lighten must never offer for cleanup. Consumers must preserve these protections before presenting cleanup choices.

### SafetyDocument

`SafetyDocument.markdown(rules:)` renders a set of `NeverRule` values as the checked-in safety reference at `docs/SAFETY.md`. Its default input is `NeverRule.all`; `SafetyDocumentTests` verifies that the generated output and checked-in document stay identical.
