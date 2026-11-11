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
   rm -rf .build/warnings
   swift build --build-tests --scratch-path .build/warnings \
     -Xswiftc -warn-concurrency > .build/warnings.log 2>&1
   ( ! grep -E '\.swift:[0-9]+:[0-9]+: warning:' .build/warnings.log )
   swift build -c release
   ./script/test_packaging.sh
   git diff --check
   ```

5. Open a pull request using the repository template.

The `.build/warnings` step fails the gate on any compiler warning in the
package's sources and tests. The Swift 6.4 compiler leaves some concurrency
diagnostics, such as a call to a main actor-isolated function from a
nonisolated context, as warnings even under `-warnings-as-errors`, so the strict
step can print them and still pass. The step builds from an empty scratch
directory because an incremental build does not print warnings again for files
it does not recompile. The pattern needs a Swift file, line, and column, as every
compiler diagnostic has, so it skips notices that SwiftPM prints about its
caches and the runtime issues that SwiftUI reports, with a line but no column,
while tests run. If the build itself
fails, read `.build/warnings.log`; after a failed grep, the lines it printed
are the warnings to fix. `Package.swift` enables complete concurrency checking
for both targets, so ordinary `swift build` and `swift test` runs show the same
diagnostics.

The [CI workflow](.github/workflows/ci.yml) enforces most of this gate. On every
push to `main`, on every pull request, and on manual dispatch, GitHub Actions
runs it on a `macos-26` runner with Xcode 26.6: the script syntax check, the
debug build with warnings as errors, `swift test`, the strict step, and a check
that fails on any Swift compiler warning in the logs of those steps. It does
not run code coverage, the release build, or `script/test_packaging.sh`, which
launches the app. Run the whole gate locally as well, including the packaging
test, and say in the pull request which steps you ran.

Dependabot opens weekly version-update pull requests for the package's
dependencies (`.github/dependabot.yml`), and with Dependabot alerts and
security updates on, it also opens a pull request when an advisory affects one.
Merge a Dependabot pull request only after its CI checks pass and the full gate
passes locally on its branch.

Tests that need settings create them with
`InMemoryUserDefaults(suiteName: "TaskScope.<TestClass>.\(UUID().uuidString)")`
from `Tests/TaskScopeTests/InMemoryUserDefaults.swift`, never with
`UserDefaults(suiteName:)`. Each instance is its own in-memory domain, so
parallel test processes cannot overwrite each other's fixtures and a run leaves
no preference files behind.

The packaging test requires macOS and Xcode 26 and launches test copies of the
app. It stages and signs them ad hoc in its own temporary directory, never in
the checkout's `dist/`, uses a unique test bundle identifier, and checks for
leaked test preferences; startup verification uses volatile defaults without
normal background enforcement. Run it only in an environment where launching
the test app is appropriate. `script/test_release_compatibility.sh` runs the
release and evidence tests on their own, or one group with `--packaging-only`,
`--pipeline-only`, or `--evidence-only`. `script/build_and_run.sh`,
`script/install.sh`, and `script/release.sh` list their modes and environment
variables with `-h` or `--help`; an unknown or second argument is a usage
error.
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

Run an external tool with `ShellCommandRunner.run(executable:arguments:)`,
giving its absolute path and its arguments as an array: the tool receives them
as given, with no shell in between, so no value needs quoting. Never build a
command string from a preset field or any other value.

Changes to a trust boundary must update [THREAT_MODEL.md](THREAT_MODEL.md).
Changes to stored or surfaced data must update [PRIVACY.md](PRIVACY.md). Release
process changes must update [RELEASE.md](RELEASE.md). Add a
[CHANGELOG.md](CHANGELOG.md) entry under [Unreleased] in the same commit as any
user-visible or trust-boundary change.

By contributing, you agree that your contributions are licensed under the
project's [MIT License](LICENSE).
