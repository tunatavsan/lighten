# Security Policy

Lighten moves and deletes files, so bugs that could remove the wrong data are treated as security issues.

## Reporting a vulnerability

Please do not open a public issue. Report privately through GitHub instead: open the
[Security tab](https://github.com/tunatavsan/lighten/security) of this repository and choose
**Report a vulnerability**.

Examples of what to report:

- A way to make Lighten move or delete an item outside the user's confirmed selection.
- A bypass of the protected locations listed in [docs/SAFETY.md](docs/SAFETY.md).
- Following a symbolic link, crossing into another volume or acting on a changed item during removal.
- Undo restoring the wrong item or overwriting an existing file.
- Corruption of the action journal that hides or misreports what Lighten did.

Please include the macOS version, the Lighten commit or version, and steps to reproduce. You can expect an initial
response within a week. Fixes are released as soon as they are verified, and reporters are credited unless they prefer
otherwise.

## Supported versions

Lighten is in early development. Security fixes are made on the `main` branch.
