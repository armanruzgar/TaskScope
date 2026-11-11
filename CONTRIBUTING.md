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
for both Swift targets, so ordinary `swift build` and `swift test` runs show the
same diagnostics.

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

Each test file is named after its test class (or holds only classes whose
names contain the file's name), so `swift test --filter <file or class name>`
selects exactly those tests; `TestFileNamingTests` fails the suite when a file
runs no tests or a class does not match its file. Code shared between tests
lives in `Tests/TaskScopeTests/Support/` and declares no tests. Use its fakes
instead of declaring new ones:

- `ScriptedInventory` returns scripted process-list reads in order and fails
  the test on a read past the script, unless the test passes `repeatsLast: true`
  (or uses `ScriptedInventory(processes:)` for a fixed list). It counts reads,
  records the extended-stats flag of each, and can hold numbered reads until
  the test releases them.
- `FakeSignaler` records every signal and answers per PID: delivered (the
  default), refused, or no such process; targets can exit on SIGTERM or SIGKILL,
  and `FakeSignaler.forbidding(_:)` fails the test on any signal.
- `FakeLifecycle` records every lifecycle call and fails the test on a call
  whose stub is unset; `FakeLifecycle.allSucceeding()` sets every stub
  explicitly for tests about something else, and `forViewTests()` is the view
  fixtures' version.
- `ProcessLifecycleRuntime.fake(...)` builds a runtime from the members a test
  passes; any other member fails the test when reached.
- `AppProcess.fixture(...)` and `WatchedAppPreset.fixture(...)` are the one place
  tests build those models, so a new field needs one change.

A fake that models something these cannot, such as a read that blocks until a
cancellation or a simulated set of running processes, stays next to its tests.

Tests that need settings create them with
`InMemoryUserDefaults(suiteName: "TaskScope.<TestClass>.\(UUID().uuidString)")`
from `Tests/TaskScopeTests/Support/InMemoryUserDefaults.swift`, never with
`UserDefaults(suiteName:)`. Each instance is its own in-memory domain, so
parallel test processes cannot overwrite each other's fixtures and a run leaves
no preference files behind.

Tests of preset lifecycle actions run the production code on a fake
`ProcessLifecycleRuntime`, for example
`SystemProcessLifecycleService(runtime: fake)`. The runtime has no default
members, so every launchd command, inventory read, signal, wait and clock
the test can reach is one it wrote; `ProcessLifecycleRuntime.live` is the only
real one. Give `sendSignal` a closure that fails the test unless the test
expects signals, and send a real signal only to a child process the test
started itself.

Test targets also depend on `TaskScopeTestEnvironment`
(`Tests/TaskScopeTestEnvironment`), a small C target that sets
`CN_UNIT_TESTING=YES` while the test bundle loads. XCTest builds its test list
by enumerating every Objective-C class in the process, and ViewInspector links
AuthenticationServices, which loads the Contacts UI frameworks. Enumerating
their classes initializes the Contacts store class, and unless that variable is
set, Contacts then starts a background warm-up that asks for Contacts access
and tries to open the user's Contacts database. A new test target must depend
on `TaskScopeTestEnvironment` too; `TestEnvironmentTests` checks that the setup
ran.

Views take the process-wide services they use instead of reaching for them.
`TaskScopePopoverView` takes the command bus its Presets Refresh submits to
(the app passes `AppCommandBus.shared`) and its Quit action, which has no
default, so a view built in a test can never quit the test process.
`SettingsView` takes the `HotkeyManager` and `NotificationService` it shows.
Tests pass their own from `Tests/TaskScopeTests/Support/ViewTestDependencies.swift`:
a private bus, a Quit that only counts, `HotkeyManager.forTests()` on in-memory
preferences with a backend that registers nothing, and
`NotificationService.forTests()`, which never touches the notification center.

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

### App Intents and App Shortcuts

[script/expected_intents.json](script/expected_intents.json) is the one list of
the App Intents actions, entities and queries, and of each App Shortcut's
phrases, that a packaged TaskScope declares. Staging, `script/install.sh` and
`script/release.sh` all check a bundle's `Metadata.appintents` against it with
the shared `taskscope_verify_bundle_metadata` in `script/packaging_common.sh`,
and Settings > Health applies the same exact-match rule to the running app. When
you add, rename or remove an intent, entity, query or App Shortcut phrase in
`Sources/TaskScope/Services/TaskScopeIntents.swift`, update the JSON in the same
change and run `./script/generate_expected_intents.sh`, which embeds the file in
the app as `ExpectedAppIntents+Source.swift`. `ExpectedAppIntentsTests` fails
while the embedded copy differs from the file, or while the list differs from
`TaskScopeShortcuts.appShortcuts`, and staging fails while the packaged metadata
differs from the list. The macOS deployment target comes from `Package.swift`
alone, through `taskscope_resolve_minimum_system_version`.

### README screenshots

The images in `docs/images` are rendered, never captured from a real session.
`./script/render_screenshots.sh` runs one test,
`ReadmeScreenshotTests/testRenderReadmeScreenshots`, with
`TASKSCOPE_RENDER_SCREENSHOTS=1`; otherwise that test is skipped, so a normal
`swift test` run reports it as skipped. The test draws the real main window,
menu-bar popover, and Process Detail sheet into off-screen windows from the
fixed fake processes, account names, history, and time in
`Tests/TaskScopeTests/ReadmeScreenshotTests.swift`, and adds the window frame
and shadow itself. Nothing is launched, no window appears on screen, and the
screen is never captured, so no real process list, user name, or path can reach
an image. It writes `main-window-light.png`, `main-window-dark.png`,
`menu-bar-presets-light.png`, `menu-bar-presets-dark.png`,
`process-detail-light.png`, and `process-detail-dark.png`; `--output DIR`
writes them elsewhere for a first look. The images are 2x, so render on a Mac
whose main display is a Retina display. Windows that are never shown are never
the active window, so controls draw in their inactive style.

Re-render after a change that shows in the main window, the menu-bar popover,
or Process Detail, review every image, and commit them with the change. Change
what they show in the test's fixtures, never by hand. Do not replace them with
a `screencapture` or any other capture of a real Mac.

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
command string from a preset field or any other value, and never run a shell:
`testNoProductionCommandRunsThroughAShell` fails if production code names one.
Tests that need shell syntax for their own child processes use
`ShellCommandRunner.runShellScript`, an explicit `/bin/sh -c` that exists only
in the test target.

Changes to a trust boundary must update [THREAT_MODEL.md](THREAT_MODEL.md).
Changes to stored or surfaced data must update [PRIVACY.md](PRIVACY.md). Release
process changes must update [RELEASE.md](RELEASE.md). Add a
[CHANGELOG.md](CHANGELOG.md) entry under [Unreleased] in the same commit as any
user-visible or trust-boundary change.

By contributing, you agree that your contributions are licensed under the
project's [MIT License](LICENSE).
