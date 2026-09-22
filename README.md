# Lighten

Lighten is a pre-alpha macOS utility. Cleanup and health features are not implemented yet.

It requires macOS 26 or later and Xcode 26 with the matching Swift toolchain. To build and run the tests without a signing identity:

```sh
swift build
swift test
```

To package and launch the app, install a valid Apple Development or Developer ID Application signing identity, then run `scripts/run.sh`. Set `LIGHTEN_SIGN_IDENTITY` to an installed identity name if more than one is available. The app is signed with hardened runtime; `scripts/package_app.sh release` also writes `dist/Lighten.dSYM`.
