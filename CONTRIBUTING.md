# Contributing to Lighten

Thank you for helping. Lighten moves people's files, so every change is held to two standards: it must be correct,
and it must be honest about what it did and did not do.

## Before you start

- For anything larger than a small fix, open an issue first so we can agree on the approach.
- Security problems go through the private process in [SECURITY.md](SECURITY.md), not public issues.

## Setting up

You need macOS 26 or later and Xcode 26 (Swift 6.2). The project is a plain Swift package with no dependencies.

```sh
git clone https://github.com/tunatavsan/lighten.git
cd lighten
swift build
swift test --no-parallel
scripts/run.sh   # package a debug build into dist/ and open it
```

## Making a change

1. Create a branch from `main`.
2. Keep the change focused. Refactors and behavior changes belong in separate pull requests.
3. Add or update tests. New behavior needs a test that fails without your change. Tests use Swift Testing and must
   create their own fixtures in a temporary directory; never read or modify real user data.
4. Run the same checks as CI:

   ```sh
   swift build
   swift test --no-parallel
   swift format lint --strict -r Sources Tests
   ```

   `scripts/format.sh` formats the code in place.
5. Open a pull request and describe what changed, why, and how you tested it.

## Guidelines

- **Safety rules are not negotiable.** Do not weaken a rule in `NeverRule.all` or bypass the plan, journal or Undo
  pipeline. If you change the rules, regenerate [docs/SAFETY.md](docs/SAFETY.md) with
  `LIGHTEN_UPDATE_SAFETY_DOC=1 swift test` and explain the change in the pull request.
- **Evidence over guesses.** New cleanup suggestions need a documented location or verifiable ownership. Names alone
  are never enough.
- **Say what happened.** When an operation is partial, skipped or refused, the UI must say so and give the reason.
- **User-facing text** uses `String(localized:)` and lives in `Resources/Localizable.xcstrings` with English and
  Turkish translations.
- **Concurrency.** The app target uses Swift 6 strict concurrency with main-actor isolation by default. Keep file
  system work off the main actor.
- **Architecture.** Read [ARCHITECTURE.md](ARCHITECTURE.md) before changing scanning, planning or execution. Its
  Contracts section describes invariants that tests rely on.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `perf:`, `refactor:`, `test:`,
`docs:`, `build:`, `ci:` or `chore:`, followed by a short imperative summary, for example
`fix: keep partial folder sizes labeled as lower bounds`.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
