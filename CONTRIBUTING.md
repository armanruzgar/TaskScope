# Contributing to TaskScope

Thanks for helping improve TaskScope.

## Before opening an issue

- Search existing issues for the same behavior.
- Use the bug report template for reproducible defects and copy the exact
  version/build from About TaskScope.
- State whether the app was source-built, Apple Development-signed, ad-hoc
  signed, or obtained as a published artifact.
- Do not include private process lists, command lines, usernames, preset paths,
  organization names, or other machine-specific data in a public report.
- Follow [SECURITY.md](SECURITY.md) for suspected vulnerabilities and
  [SUPPORT.md](SUPPORT.md) for support and recovery questions.

## Development environment

The package declares macOS 14 as its deployment target. Use Xcode 26 or newer
(full Xcode, not only the Command Line Tools) for the build, the full test
suite, and App Intents metadata packaging. `Package.swift` declares Swift tools
5.9, but the sources need at least Xcode 16 with the macOS 15 SDK to compile:
they call an App Intents API that older SDKs do not declare, and they use
`nonisolated(unsafe)`, which needs Swift 5.10. The current local packaging
evidence is arm64.
Do not claim compatibility with another OS version or architecture based only on
a successful cross-build.

## Development workflow

1. Fork and clone the repository.
2. Create a focused branch from `main`.
3. Make the smallest coherent change and add regression coverage.
4. Run the complete local quality gate from the repository root:

   ```bash
   ( for f in script/*.sh; do bash -n "$f" || exit 1; done )
   swift build -c debug -Xswiftc -warnings-as-errors
   swift test
   swift test --enable-code-coverage
   swift test --scratch-path .build/strict \
     -Xswiftc -warnings-as-errors \
     -Xswiftc -warn-concurrency \
     -Xswiftc -enable-actor-data-race-checks
   swift build -c release
   ./script/test_packaging.sh
   git diff --check
   ```

5. Open a pull request using the repository template.

Tests that need settings create them with
`InMemoryUserDefaults(suiteName: "TaskScope.<TestClass>.\(UUID().uuidString)")`
from `Tests/TaskScopeTests/InMemoryUserDefaults.swift`, never with
`UserDefaults(suiteName:)`. Each instance is its own in-memory domain, so
parallel test processes cannot overwrite each other's fixtures and a run leaves
no preference files behind.

The packaging test requires macOS and Xcode 26 and launches the staged app.
It uses a unique test bundle identifier and checks for leaked test preferences;
startup verification uses volatile defaults without normal background enforcement.
Run it only in an environment where launching the test app is appropriate.
If a contributor cannot run a platform-specific gate, say exactly which command was not run and why; do not
report it as passing. A maintainer must run every release gate before tagging.

## Security-sensitive changes

Keep pull requests focused. Explain user-visible changes and explicitly call out
anything affecting:

- process discovery, identity, signaling, or destructive confirmations;
- imported preset fields or privileged lifecycle operations;
- URL schemes, Shortcuts, login items, Accessibility, or notifications;
- preference schemas, migrations, corruption recovery, or deletion;
- bundle identity, architecture, signing, notarization, or packaging.

Changes to a trust boundary must update [THREAT_MODEL.md](THREAT_MODEL.md).
Changes to stored or surfaced data must update [PRIVACY.md](PRIVACY.md). Release
process changes must update [RELEASE.md](RELEASE.md). Add a
[CHANGELOG.md](CHANGELOG.md) entry under [Unreleased] in the same commit as any
user-visible or trust-boundary change.

By contributing, you agree that your contributions are licensed under the
project's [MIT License](LICENSE).
