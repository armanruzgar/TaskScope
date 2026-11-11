# Release and Rollback Guide

This is the maintainer runbook for producing an honest TaskScope release. A
release is complete only when its tag, notes, artifacts, and documented claims
match independently verified evidence. A changelog entry, local install, or
staged app is not itself a published release.

## Current 1.1.0 scope

- Version: `1.1.0`
- Build: `3` (the 1.0.0 tag carries build `2`; `script/release.sh` refuses a
  build number that is not greater than every `v*` tag's)
- Deployment target: macOS 14
- Verified packaging architecture: arm64 only
- Distribution: GitHub source release and local-development packaging
- Tag: `v1.0.0` points to `70be2a5`. The public history is a rewritten copy of
  the original repository, so commits from before 2026-10-17 have different
  SHAs; [Evidence/README.md](Evidence/README.md#commit-shas-in-older-records)
  maps the SHAs that older records cite
- Releases: 1.1.0 (tag `v1.1.0`, 2026-11-10) is the latest source release;
  1.0.0 is superseded. Because both tags exist, `script/release.sh` refuses
  `VERSION` 1.0.0 and 1.1.0; before the next release, raise `VERSION` and move
  the `[Unreleased]` changelog entries under a `## [<version>]` heading
- Local bundle identifier: `com.local.TaskScope`
- Possible local signatures: Apple Development or ad-hoc, both with the hardened
  runtime; only `--debug` builds add the `get-task-allow` debugging entitlement
- Not provided or claimed: production bundle identity, universal/Intel binary,
  Developer ID signature, hardened-runtime review, notarization, stapling, or a
  public downloadable app bundle

Do not attach `dist/build.noindex/TaskScope.app` or an archive of it to a GitHub
source release as a production binary. GitHub's generated source archives are
the only release artifacts within this scope unless the credential-gated
pipeline and full binary gate below complete with real Apple credentials.

Process fixes scope watched main/helpers, the Watched filter, and preset signals
to the current user; main detection uses Contents/MacOS and helpers use Contents.
Start evidence uses UTC and names preserve UTF-8. Shared inventory freshness
uses monotonic time including sleep; Open polling has a monotonic deadline and
attempt bound. Shell completion retries early child-reaping probes, including
after timeout. Executable-path identity checks remain required.

Regression coverage uses injected clocks/inventories, owned child processes with
injected transient reap results, and fake lifecycle commands/signals. It checks
captured-preset verdicts, nonzero bootout followed by verified removal,
missing-bundle override recovery without saved intent, truthful restoration
reports, PID reuse during escalation, privileged script ordering/short-circuit
guards, and delivered fake signals in missing-plist tests. It also covers
cancellation after fake SIGTERM with continued Stop escalation/helpers,
cancelled Open readiness, changed executable evidence, notification path edits,
joined refreshes, self-PID refusal, and complete GlobalProtect job scopes.
Additional fake-runtime coverage checks separate watched freshness dates,
extended metrics after stale stops, defunct-process exit reporting, unsignalled
rule-edit cancellation, unanswered prompts after executable moves, prompt
reporting of definitive bootout refusals, and loaded GlobalProtect jobs without
running PIDs.
Malformed job output remains unknown. Inventory-failure regressions require
unverified targets and exact verification-failure messages and results.
These checks do not establish live clock-change, launchctl error, App Intent
cancellation, Fast User Switching, or managed GlobalProtect compatibility.

## Release inputs

Before starting:

1. Confirm the release scope and whether any prior build reached users.
2. Confirm `VERSION`, `BUILD_NUMBER`, and changelog date/notes. Build numbers
   must increase monotonically for every distributed artifact of a version.
   Compatibility Self-Check accepts positive integer TaskScope builds up to 64
   digits independently of GlobalProtect version syntax. Retained evidence
   must identify the exact candidate build.
3. Confirm the working branch is the default branch, its upstream is known, and
   the worktree contains no unrelated changes.
4. Fetch the remote and stop if history has diverged or the branch is behind in
   a way that cannot be updated by a normal fast-forward/rebase workflow.
5. Inventory the actual macOS versions, architectures, signing identities, and
   managed-product environments available for QA. Missing coverage must be
   stated, not inferred.
6. Review [THREAT_MODEL.md](THREAT_MODEL.md), [PRIVACY.md](PRIVACY.md), all
   security-sensitive changes since the prior release, and any open Dependabot
   alerts. Dependabot alerts and security updates are on for the repository's
   dependencies; a Dependabot pull request is merged only after its CI checks
   pass and the full gate passes locally on its branch.
7. If the main window, the menu-bar popover, or Process Detail changed since
   the last release, re-render the README screenshots with
   `./script/render_screenshots.sh` and review them. They show synthetic data
   only; see [CONTRIBUTING.md](CONTRIBUTING.md#readme-screenshots).

## Canonical automated gate

Run from the repository root on a clean checkout with Xcode 26 or newer:

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

The `.build/warnings` step fails on any compiler warning in the package's
sources and tests; [CONTRIBUTING.md](CONTRIBUTING.md#development-workflow)
explains why the strict step alone is not enough. The
[CI workflow](.github/workflows/ci.yml) runs the script syntax check, the debug
build, `swift test`, the strict step, and the compiler-warning check on every
push to `main` and on pull requests, using Xcode 26.6 on GitHub's `macos-26`
runner. It does not replace this gate: code coverage, the release build, and
the packaging test run only locally, and the recorded local results remain the
release evidence.

`script/test_packaging.sh` stages, signs ad hoc, and launches test copies of the
app in its own temporary directory; the checkout's `dist/` and
`Package.resolved` end the run unchanged. It uses a unique test bundle
identifier, rejects test preference plists outside its temporary directory, and
cleans up that domain and its plists. Startup verification uses volatile defaults;
a temporary `CFFIXED_USER_HOME` alone does not isolate preferences.

Record the toolchain (`sw_vers`, `swift --version`, and `xcodebuild -version`)
and the pass/fail result of every command. Do not dismiss a failure as
environmental without reproducing and documenting its cause.

## Manual release QA

Use disposable controlled processes for Stop and Force Stop. Never use a
production workload or managed security daemon merely to exercise a destructive
test.

Record evidence for every locally testable item:

- clean install and upgrade from existing preferences;
- bundle-ID migration behavior where the identifier changes;
- Stop, Force Stop, process exit, PID reuse, selection, and batch reporting;
- watched-app open/close success, absent files, partial failures, and denial;
- Prompt, Auto Stop, and Log Only ownership/self exclusion, queue-head
  replacement, and quick-sheet disclosure when supplying a path enables a
  disabled name-only Auto Stop rule;
- automatic retry timing after unrelated and still-matching in-flight edits;
  automated coverage uses a fake monotonic clock;
- quick presets reject unmatched main/helper owners, names, and paths, including
  non-bundled tools and extensions/XPC services selected as mains;
- mixed auto-stop event recovery preserves valid entries and the original
  payload, remains read-only, and commits recovered history only on reset;
- saved-selection recall read failure, background inventory failure/recovery,
  per-user Services badges, and TaskScope self-stop menu/Return protection;
- corrupt settings, presets, rules/events, and saved-selection recovery/reset;
  wrong-type preset values publish no fallback watched-app targets in Shortcuts;
- notification not-determined, allowed, denied, revoked, and recovery states;
- Accessibility not-granted/granted messaging and Activity Monitor identity
  handoff, including root-owned and other-user processes, PID reuse,
  changed/unreadable kernel paths, identity changes during opening/retries/selection,
  and consecutive handoffs before restoration;
- Launch at Login registration, required approval, and UI-driven removal/error
  recovery in Requires Approval and Unavailable states;
- hotkey conflict, previous-shortcut restoration, separate recording errors, and
  invalid saved-shortcut migration to ⌃⌥⌘T with a reason that survives relaunch
  until dismissal or successful recording;
- wrong-type hotkey backup, read-only recovery, reset, full backup slots, and
  preservation of unknown dictionary fields;
- cold and warm `taskscope://refresh`, plus rejection of every other URL route;
- Shortcuts cold launch with an eligible signature, without unintended window
  or Dock icon; query-only parameter pickers, pickers open beyond the launch
  grace period, late intents, and intents in an already-interactive app;
- Stop confirmation and cancellation from Shortcuts, Siri, Spotlight, and App Shortcuts;
- Get Watched App Status from a shortcut's **If** action and from "Get *preset*
  status in TaskScope", with the preset running, quiet, kept off, and with a
  failed read (Stale, then Unknown after a fresh launch); it changes nothing;
  Open and Stop return the same value after they complete, and no action offers
  Keep Off;
- installed/staged duplicate same-identifier launch handoff before background
  enforcement, reopening the existing window after quiet login-item launches or
  window closure; startup verification leaves normal preferences untouched;
- graceful SIGTERM cleanup with a pending search save or temporary Activity
  Monitor handoff, using an appropriate test environment;
- About/onboarding use the packaged icon; changing the watched-status interval
  preserves history without immediate samples;
- the menu-bar icon's marks on macOS 14 and on 26 or later, in light and dark
  menu bars: plain, a running watched app, a kept-off service running again, a
  failed read (stale) and a fresh launch (unknown), and a waiting Auto-Stop
  prompt; the status item keeps its width in every state, VoiceOver reads each
  state, and turning **Show status in the menu-bar icon** off stops background
  reads when notifications and Keep Off are off;
- light/dark appearance, keyboard operation, VoiceOver labels, and destructive
  confirmations. In tree mode, focus search, click the highlighted row again,
  and verify the arrows (Left and Right collapse and expand), Space, Return,
  Command-I, and Escape, which clears only the keyboard row and keeps the
  selection; repeat with a child row. Verify Cancel
  and normal/force single and batch confirmations in window and menu bar using
  safe test targets. Automated confirmation checks assert exact SIGTERM/SIGKILL
  delivery and settled Cancel behavior, with mutation checks.

GlobalProtect restoration requires an appropriate managed test machine. If one
is unavailable, test only safe simulations and document the missing external
coverage. Likewise, do not claim macOS 14, Intel, or universal runtime support
without the corresponding machine or VM evidence.

### GlobalProtect compatibility evidence gate

Use **Compatibility Self-Check** on the built-in preset and retain the redacted
export with the tested source revision or artifact identifier. Follow the
matrix and procedure in
[GLOBALPROTECT_COMPATIBILITY.md](GLOBALPROTECT_COMPATIBILITY.md). The export
records actual versions, known optional-agent layout, launchd override/loaded
states, process ownership counts, and protected-service verification. It does
not certify VPN health, policy behavior, or persistence across login/reboot.

Keep fixture tests, live read-only observations, and authorized lifecycle smoke
tests in separate evidence rows. For each claimed GlobalProtect/macOS/CPU
combination, require before/after reports and manual results for Keep Off,
TaskScope relaunch, login/reboot persistence, and Open/restoration. Record any
unknown probe, unexpected label, unverified protected service, or managed-policy
interference as a coverage gap. Do not promote a row to supported on the basis
of a passing parser test or a single snapshot. If no managed lifecycle test was
performed, release notes must explicitly say **GlobalProtect lifecycle
compatibility unverified** and retain the existing source/development scope.

Recent lifecycle changes have fixture coverage only: background polling preserves
session VPN services and ignores them as enforcement triggers; unchanged failures
are not republished. Session layouts preserve loaded system daemons with matching
incomplete-stop advice. Recovery-mode intent, deletion during queued actions or
disconnect, captured-preset verification, PanGPS job/PID attribution, and five
consecutive idle observations after a Connected reset have fake-runtime tests.
Shutdown/readiness waits are bounded, failed user-agent restoration retains Keep
Off intent, and polling cancellation produces no failure report. Validate these
cases, including Fast User Switching and vendor UI routing, on an authorized
managed test machine before claiming live compatibility.

Both public-binary modes of `script/release.sh` enforce the
[machine-checkable evidence contract](GLOBALPROTECT_COMPATIBILITY.md#machine-checkable-release-evidence).
For the exact version/build, retain at least one tracked `.evidence` manifest
directly in `Evidence/GlobalProtect/lifecycle/<version>-<build>/`, one per
tested environment (macOS build, architecture, GlobalProtect version, agent
layout, and persistence event). Every manifest must identify the tested
candidate and environment, declare no coverage gaps, record all nine
lifecycle/protected-service/VPN/policy checks as `pass`, and reference six
snapshot files plus manual observations: nonempty files with distinct paths and
distinct contents, none of them a `.evidence` file. The test date must be a
real date, not in the future, and not earlier than the tested commit's author
date (one day is allowed for time zones). Paths must stay
inside that candidate's evidence directory without symlinks. All candidate
content outside the evidence directory tree and three release documents must
match the tested source revision. Evidence-only follow-up commits are allowed.

Missing, malformed, incomplete, failed, or stale evidence stops preflight and
the full release before build, signing, or notarization. The error names the
missing requirement and links to the collection contract; credentials cannot
bypass it. The current read-only observation and fixtures intentionally fail
this gate. Do not fabricate a passing manifest to unblock packaging: continue
using the source/development flow until authorized lifecycle QA is available.
Machine validation checks explicit attestations and retained files; maintainers
must review their contents and keep compatibility claims within that coverage.

## Local source/development release verification

Stage and verify the current-architecture bundle. Staging stops verified running
copies of the staged app before replacement, including when invoked by the
installer, release pipeline, or packaging tests. Static and startup verification
hold the packaging lock for the full check. Installation holds it through
validation/copying and rechecks the copied identifier, version, and build before
replacement and after installation. Another running copy with the same bundle
identifier must be quit before a script opens/debugs a different bundle path.
Startup verification launches with fresh volatile store/onboarding preferences
and no normal background enforcement; the verification copy rejects every URL,
Shortcut, or popover command at once and quits by itself after 60 seconds:

```bash
./script/build_and_run.sh --stage
./script/build_and_run.sh --verify   # verifies the bundle staged above without rebuilding it
codesign --verify --deep --strict dist/build.noindex/TaskScope.app
lipo -archs dist/build.noindex/TaskScope.app/Contents/MacOS/TaskScope
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' dist/build.noindex/TaskScope.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/build.noindex/TaskScope.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' dist/build.noindex/TaskScope.app/Contents/Info.plist
```

Inspect the displayed signature with `codesign -dv --verbose=4`. Record it as
ad-hoc or Apple Development exactly as shown. These checks do not establish
Developer ID distribution trust or notarization.

## Credential-gated public binary pipeline

Run the credential-independent validation with a syntactically valid
non-development candidate identifier and the retained lifecycle evidence above:

```bash
TASKSCOPE_BUNDLE_ID=com.example.TaskScope ./script/release.sh --preflight
```

`script/release.sh` takes exactly one mode, `--preflight` or `--release`; there
is no default, `-h` or `--help` lists the modes and environment variables, and
any other or additional argument is a usage error. Preflight validates
identifier syntax and rejects the local development prefix; it does not verify
ownership. It also validates version/build, arm64 host/policy, the GlobalProtect
lifecycle evidence contract, and required tools. It refuses a version whose
`v<version>` tag already exists, requires a literal `## [<version>]` changelog
heading with no entries left under `## [Unreleased]`, and refuses to overwrite
release output from an earlier run. With the repository's current unverified
lifecycle coverage, this command is expected to fail with collection
instructions. After
evidence passes, it reports missing credentials but does not sign, notarize, or
create a releasable artifact.

The evidence regression tests run as part of `script/test_packaging.sh` and can
also run alone with `bash script/test_release_compatibility.sh`, which also
takes `--evidence-only`, `--packaging-only`, or `--pipeline-only` to run one
group. They use only synthetic files in a disposable Git repository and stub
release tools; their passing results are not installed-product compatibility
evidence. Packaging tests clear inherited packaging and release inputs, so
exported production settings do not change their development defaults.

The full pipeline requires all of these environment variables:

- `TASKSCOPE_BUNDLE_ID`: a non-`com.local.*` production identifier whose
  ownership the maintainer has verified separately;
- `TASKSCOPE_CODE_SIGN_IDENTITY`: an available `Developer ID Application: ...`
  identity with its private key;
- `TASKSCOPE_EXPECTED_TEAM_ID`: the corresponding ten-character Apple Team ID;
- `TASKSCOPE_NOTARY_KEYCHAIN_PROFILE`: an existing `notarytool` keychain
  profile;
- optional `TASKSCOPE_RELEASE_ARCHS=arm64`, whose only accepted value for the
  first release is `arm64`;
- `TASKSCOPE_FIRST_RELEASE=1` only for a first public binary release when the
  repository has no release tags yet; it acknowledges that no build-number
  history exists.

`TASKSCOPE_KEEP_RELEASE_WORK=1` keeps the work directory of a failed run for
diagnosis. With those values configured securely outside Git, run:

```bash
./script/release.sh --release
```

The script fetches the origin's tags and requires a clean worktree on the
default branch whose `HEAD` equals its fetched upstream. It validates identifier
syntax, version, build (which must exceed the maximum build number across all
`v*` tags, including prereleases and hotfixes; missing or invalid tagged values
fail), the changelog heading and empty `[Unreleased]` section, arm64
architecture, retained GlobalProtect lifecycle evidence, the deployment target
(read from `Package.swift`), and the bundle's Info.plist values and App Intents
actions, entities, queries and App Shortcut phrases, which must match
`script/expected_intents.json` exactly, as staging requires. It builds from a
generated app-only package, so the release build never resolves the test
dependencies or rewrites `Package.resolved`, and rechecks the worktree after
the build. It builds with hardened runtime and no entitlements, removes
build-machine run paths and rejects non-system run paths and `@rpath`
libraries, extracts the dSYM and then strips the distributed binary, verifies
the Developer ID team, creates matching app/dSYM UUIDs, submits to Apple,
staples and Gatekeeper-verifies the app, and round-trips the final ZIP. It
stages in its own work directory, leaving `dist/build.noindex` alone, and emits
the app ZIP, dSYM ZIP, notary result, provenance, and verified `SHA256SUMS`
under `dist/releases/`, named `TaskScope-<version>-<build>-macOS-arm64…`. The
provenance records the commit and also the branch, upstream, remote URL, and
remote `HEAD`. A failed run removes its work unless
`TASKSCOPE_KEEP_RELEASE_WORK=1` is set; notarization logs are kept in
`dist/TaskScope-notary-diagnostics.*`, and work kept from an earlier failed run
is removed when the next full release starts.

Successful script output is necessary but does not prove bundle-identifier
ownership, migrate preferences or permissions, or replace manual clean-machine,
upgrade, cross-version, and managed-product QA. A failed or unrun credentialed
pipeline is not evidence of signing or notarization.

## Additional gate for a public binary

A public app archive, ZIP, DMG, or installer is allowed only after all of these
are true:

1. An owned production bundle identifier is configured consistently throughout
   build, install, logs, URL registration, App Intents, and login items.
2. Existing preference/permission identity is migrated and upgrade-tested, or
   the release clearly documents a deliberate break before installation.
3. The architecture policy is explicit. A universal claim is verified with
   `lipo -archs`; an arm64-only artifact is labeled arm64 everywhere.
4. Hardened runtime and any entitlements have been reviewed and verified from
   the signed artifact.
5. The app is signed with an authorized **Developer ID Application** identity
   and a secure timestamp. No certificate or credential is stored in Git.
6. Apple notarization succeeds for the exact archive and its ticket is stapled
   where the artifact format supports stapling.
7. `codesign`, `spctl`, and `stapler validate` succeed against the final copy.
8. A SHA-256 checksum is produced after all signing/notarization/stapling and is
   published alongside the artifact.
9. Install, first launch, Shortcuts, URL refresh, permissions, upgrade, and
   uninstall succeed on a clean machine using the downloaded copy.
10. The GlobalProtect lifecycle evidence gate passes for the candidate, and
    reviewers confirm the retained observations support every advertised
    environment and lifecycle claim.

Never print or commit credential values. If an Apple certificate, notary
credential, paid enrollment, owned identifier, or test machine is missing,
finish all credential-independent checks and label the release source only.

## Commit, tag, and publish

1. Review the complete diff and rerun the gate after the final change.
2. Commit the release preparation to the default branch with a descriptive
   message and push normally. Never force-push or rewrite public history; a
   repository ruleset blocks force-pushes to `main` and its deletion, while
   ordinary pushes still work.
3. Verify the pushed commit is the intended release commit and confirm the
   recorded local gate output (see "Canonical automated gate") passed for that
   exact commit. The CI workflow's checks for that commit must also have
   passed. They cover script syntax, the debug build, the tests, the strict
   step, and compiler warnings, but not code coverage, the release build, or the
   packaging test, so they complement the local gate rather than replace it.
4. Create `v<version>` at that exact commit. Use the repository's configured
   signed-tag mechanism; if no signing mechanism exists, do not claim the tag is
   signed. For a public binary, `script/release.sh --release` must complete
   before this step: the script refuses a version whose tag exists, so
   rebuilding a tagged release needs a new version.
5. Push the tag normally. Once pushed, a `v*` tag cannot be moved or deleted:
   a tag ruleset blocks both.
6. Publish a GitHub release using the changelog, explicitly identifying it as
   source/development-only when the public binary gate was not completed.
7. Verify the release page, tag target, source archives, notes, and every link
   from a clean or logged-out context as visibility permits.
8. Confirm `git status -sb` is clean and synchronized.

Do not publish a release link in prose as evidence before the release exists.

## Installation rollback

`script/install.sh` copies to a temporary bundle, preserves the prior
installation, verifies the replacement, and restores the backup if replacement
fails. If an install or stage is interrupted outright (for example by `SIGKILL`
or power loss), the next install or stage restores a backup that was left
without a destination and removes leftover hidden bundles.
`script/test_packaging.sh` injects failures before and after replacement to
exercise that transaction.

If an installed development build must be downgraded after a successful
install:

1. Export the configuration (**Settings > General > Export Configuration…**)
   and preserve needed preference data.
2. Turn off Launch at Login and quit TaskScope.
3. Install the previously verified app bundle through the same transactional
   installer or restore a known-good backup.
4. Retained rules, presets, selections, and events preserve unknown stored JSON
   fields. Unknown rule fields disable and lock the rule in this build; newer
   settings values survive unrelated edits. This is preservation, not support
   for newer behavior. Deleted entries and events beyond the history limit are
   still removed. Preset archives retain their existing schema-version gate.
   Do not downgrade preferences across an incompatible schema unless migration
   tests prove it safe. Validate mixed valid/invalid selection recovery,
   wrong-type preference backups, and explicit-reset persistence. Diagnostics
   schema version 2 must encode unreadable saved notification/Keep Off settings
   as `null`. Recovery with no valid presets must refuse export; partial exports
   exclude rejected entries.
5. Reverify signature, version/build, startup, URL refresh, Shortcuts, and
   permissions.

## Published-release rollback

Never move an existing tag to another commit; the `v*` tag ruleset blocks moving
or deleting release tags. For a defective release:

1. Mark the GitHub release and artifact status clearly; remove a dangerous
   binary from download if necessary without erasing the tag/history.
2. Open a private security advisory first when disclosure itself creates risk.
3. Prepare a higher patch version from the last safe commit, with a build number
   greater than every existing `v*` tag, including other release lines.
4. Run the full gate and publish a new immutable tag/release.
5. Explain affected versions, mitigation, preference compatibility, and upgrade
   instructions without exposing unresolved exploit details.

After publication, monitor issues without asking users to expose private process
or organization data. Release follow-up belongs in [ROADMAP.md](ROADMAP.md).
