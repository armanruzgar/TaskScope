#!/usr/bin/env bash
set -euo pipefail

# Each case supplies its own packaging inputs, independent of release exports.
unset TASKSCOPE_BUNDLE_ID TASKSCOPE_SIGNING_STYLE TASKSCOPE_CODE_SIGN_IDENTITY \
  TASKSCOPE_VERIFIED_BUNDLE_COPY TASKSCOPE_INSTALL_FAIL_AT TASKSCOPE_SKIP_BUILD \
  TASKSCOPE_RELEASE_ARCHS TASKSCOPE_EXPECTED_TEAM_ID TASKSCOPE_NOTARY_KEYCHAIN_PROFILE \
  TASKSCOPE_OUTPUT_DIR TASKSCOPE_DSYM_COPY TASKSCOPE_FIRST_RELEASE \
  BUILD_CONFIGURATION

# Discard inherited Git repository overrides before any fixture operations.
while IFS= read -r git_variable; do unset "$git_variable"; done < <(git rev-parse --local-env-vars)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/script/build_and_run.sh"
INSTALL_SCRIPT="$ROOT_DIR/script/install.sh"
RELEASE_SCRIPT="$ROOT_DIR/script/release.sh"
COMMON_SCRIPT="$ROOT_DIR/script/packaging_common.sh"
INTENTS_GENERATOR="$ROOT_DIR/script/generate_expected_intents.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/taskscope-packaging.XXXXXX")"
export TASKSCOPE_CODE_SIGN_IDENTITY=-
export TASKSCOPE_OUTPUT_DIR="$TEST_DIR/build.noindex"
TEST_BUNDLE_ID="com.example.TaskScopeTests.Run$(/usr/bin/uuidgen | /usr/bin/tr -d '-')"
TEST_PREFERENCES_DIR="$HOME/Library/Preferences"

# Every case stages into TEST_DIR. The checkout's own staged bundle and its
# Package.resolved must end the run exactly as they started.
checkout_state() {
  /usr/bin/stat -f '%m %i' "$ROOT_DIR/dist/build.noindex/TaskScope.app/Contents/Info.plist" \
    2>/dev/null || echo 'no staged bundle'
  /usr/bin/shasum -a 256 "$ROOT_DIR/Package.resolved"
}
CHECKOUT_STATE="$(checkout_state)"

assert_no_test_preferences() {
  local path
  for path in "$TEST_PREFERENCES_DIR/$TEST_BUNDLE_ID.plist" \
    "$TEST_PREFERENCES_DIR/ByHost/$TEST_BUNDLE_ID."*.plist; do
    if [[ -e "$path" ]]; then
      echo "Startup verification wrote preferences outside $TEST_DIR: $path" >&2
      return 1
    fi
  done
}

cleanup_test() {
  local exit_code="$?"

  # bash 3.2 runs the EXIT trap with status 0 after a `set -u` abort, so only
  # a run that reached its last check may pass.
  if [[ "$exit_code" -eq 0 && "${PACKAGING_TESTS_FINISHED:-0}" -ne 1 ]]; then
    echo "Packaging tests stopped before they finished." >&2
    exit_code=1
  fi
  if ! assert_no_test_preferences; then
    [[ "$exit_code" -ne 0 ]] || exit_code=1
  fi
  # CFFIXED_USER_HOME does not isolate CFPreferences. Remove only this run's
  # unique test domain, including empty plists left by defaults deletion.
  /usr/bin/defaults delete "$TEST_BUNDLE_ID" >/dev/null 2>&1 || true
  /usr/bin/defaults -currentHost delete "$TEST_BUNDLE_ID" >/dev/null 2>&1 || true
  rm -f "$TEST_PREFERENCES_DIR/$TEST_BUNDLE_ID.plist" \
    "$TEST_PREFERENCES_DIR/ByHost/$TEST_BUNDLE_ID."*.plist
  rm -rf "$TEST_DIR"
  exit "$exit_code"
}
trap cleanup_test EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

bash -n "$BUILD_SCRIPT"
bash -n "$INSTALL_SCRIPT"
bash -n "$RELEASE_SCRIPT"
bash -n "$COMMON_SCRIPT"
bash -n "$INTENTS_GENERATOR"
source "$COMMON_SCRIPT"

# The app embeds script/expected_intents.json, the list packaging checks
# bundles against, through a generated Swift file that must be current.
"$INTENTS_GENERATOR" --check
GENERATOR_FIXTURE="$TEST_DIR/Generator"
GENERATED_SOURCE="$GENERATOR_FIXTURE/Sources/TaskScope/Models/ExpectedAppIntents+Source.swift"
mkdir -p "$GENERATOR_FIXTURE/script" "$(dirname "$GENERATED_SOURCE")"
cp "$INTENTS_GENERATOR" "$GENERATOR_FIXTURE/script/"
cp "$ROOT_DIR/Sources/TaskScope/Models/ExpectedAppIntents+Source.swift" "$GENERATED_SOURCE"
sed 's/"metadataVersion": "[^"]*"/"metadataVersion": "9.9"/' "$ROOT_DIR/script/expected_intents.json" \
  > "$GENERATOR_FIXTURE/script/expected_intents.json"
grep -Fq '"metadataVersion": "9.9"' "$GENERATOR_FIXTURE/script/expected_intents.json"
if "$GENERATOR_FIXTURE/script/generate_expected_intents.sh" --check > "$TEST_DIR/generator.out" 2>&1 \
  || ! grep -Fq 'is out of date' "$TEST_DIR/generator.out"; then
  echo "The generator check accepted a stale ExpectedAppIntents+Source.swift." >&2
  exit 1
fi
"$GENERATOR_FIXTURE/script/generate_expected_intents.sh" > /dev/null
"$GENERATOR_FIXTURE/script/generate_expected_intents.sh" --check
grep -Fq '"metadataVersion": "9.9"' "$GENERATED_SOURCE"
printf '{"broken": \n' > "$GENERATOR_FIXTURE/script/expected_intents.json"
if "$GENERATOR_FIXTURE/script/generate_expected_intents.sh" > "$TEST_DIR/generator.out" 2>&1 \
  || ! grep -Fq '"metadataVersion": "9.9"' "$GENERATED_SOURCE"; then
  echo "The generator embedded malformed JSON." >&2
  exit 1
fi

(
  /bin/sleep 30 &
  identity_test_pid="$!"
  identity_test_value="$(
    taskscope_wait_for_process_identity "$identity_test_pid" 20 /bin/sleep
  )"
  identity_test_executable="$(taskscope_process_executable_path "$identity_test_pid")"
  # Each case removes its trap on success, so the trap marks a failure.
  trap 'taskscope_signal_process_if_identity_matches KILL "$identity_test_pid" "$identity_test_value" "$identity_test_executable" >/dev/null 2>&1 || true; exit 1' EXIT

  if taskscope_signal_process_if_identity_matches \
    TERM "$identity_test_pid" "not-the-captured-identity" \
    "$identity_test_executable" >/dev/null 2>&1; then
    echo "Process signalling accepted a mismatched stable identity." >&2
    exit 1
  fi
  if ! /bin/kill -0 "$identity_test_pid" >/dev/null 2>&1; then
    echo "Mismatched process identity terminated the controlled process." >&2
    exit 1
  fi

  taskscope_signal_process_if_identity_matches \
    TERM "$identity_test_pid" "$identity_test_value" \
    "$identity_test_executable" >/dev/null
  wait "$identity_test_pid" 2>/dev/null || true
  trap - EXIT
)

(
  forged_executable="$TEST_DIR/Forged/TaskScope"
  mkdir -p "$(dirname "$forged_executable")"
  cp /bin/sleep "$forged_executable"

  bash -c 'exec -a "$1" /bin/sleep 30' taskscope-forged-argv "$forged_executable" &
  forged_pid="$!"
  forged_identity="$(
    taskscope_wait_for_process_identity "$forged_pid" 20 "$forged_executable"
  )"
  actual_executable="$(taskscope_process_executable_path "$forged_pid")"
  trap 'taskscope_signal_process_if_identity_matches KILL "$forged_pid" "$forged_identity" "$actual_executable" >/dev/null 2>&1 || true; exit 1' EXIT

  forged_command=""
  for _ in {1..20}; do
    forged_command="$(taskscope_process_command "$forged_pid" 2>/dev/null || true)"
    [[ "$forged_command" == "$forged_executable"* ]] && break
    /bin/sleep 0.05
  done
  if [[ "$forged_command" != "$forged_executable"* ]]; then
    echo "Could not establish the forged argv0 regression fixture." >&2
    exit 1
  fi

  taskscope_stop_processes_for_executable "$forged_executable"
  if ! /bin/kill -0 "$forged_pid" >/dev/null 2>&1; then
    echo "Forged argv0 caused the wrong executable to be terminated." >&2
    exit 1
  fi
  if taskscope_signal_process_if_identity_matches \
    TERM "$forged_pid" "$forged_identity" "$forged_executable" >/dev/null 2>&1; then
    echo "Kernel executable verification accepted forged argv0." >&2
    exit 1
  fi

  taskscope_signal_process_if_identity_matches \
    TERM "$forged_pid" "$forged_identity" "$actual_executable" >/dev/null
  wait "$forged_pid" 2>/dev/null || true
  trap - EXIT
)

(
  expected_executable="$TEST_DIR/Genuine/TaskScope"
  mkdir -p "$(dirname "$expected_executable")"
  cp /bin/sleep "$expected_executable"
  # A copied platform binary is killed at launch; an ad-hoc signature runs.
  /usr/bin/codesign --force --sign - "$expected_executable" >/dev/null 2>&1

  "$expected_executable" 30 &
  expected_pid="$!"
  expected_identity="$(
    taskscope_wait_for_process_identity "$expected_pid" 20 "$expected_executable"
  )"
  trap 'taskscope_signal_process_if_identity_matches KILL "$expected_pid" "$expected_identity" "$expected_executable" >/dev/null 2>&1 || true; exit 1' EXIT

  taskscope_stop_processes_for_executable "$expected_executable"
  if /bin/kill -0 "$expected_pid" >/dev/null 2>&1; then
    echo "Guarded stop helper did not terminate the genuine expected executable." >&2
    exit 1
  fi
  wait "$expected_pid" 2>/dev/null || true
  trap - EXIT
)

(
  # In the C locale (cron, launchd, many SSH sessions) ps and lsof escape a path
  # that is not ASCII. The helpers must still find and stop such a copy.
  unicode_executable="$TEST_DIR/Packaging — Apps/TaskScope.app/Contents/MacOS/TaskScope"
  mkdir -p "$(dirname "$unicode_executable")"
  cp /bin/sleep "$unicode_executable"
  /usr/bin/codesign --force --sign - "$unicode_executable" >/dev/null 2>&1

  "$unicode_executable" 30 &
  unicode_pid="$!"
  # The PID stays this shell's child until it is waited for, so it cannot be reused.
  trap '/bin/kill -KILL "$unicode_pid" 2>/dev/null || true; wait "$unicode_pid" 2>/dev/null || true; exit 1' EXIT
  if ! LC_ALL=C LANG= taskscope_wait_for_process_identity \
    "$unicode_pid" 40 "$unicode_executable" >/dev/null; then
    echo "Process identity capture failed for a non-ASCII path in the C locale." >&2
    exit 1
  fi
  LC_ALL=C LANG= taskscope_stop_processes_for_executable "$unicode_executable"
  if /bin/kill -0 "$unicode_pid" >/dev/null 2>&1; then
    echo "The stop helper missed a copy at a non-ASCII path in the C locale." >&2
    exit 1
  fi
  wait "$unicode_pid" 2>/dev/null || true
  trap - EXIT
)

(
  rejected_executable="/bin/sleep"
  taskscope_list_processes() {
    printf '4242 %s 30\n' "$rejected_executable"
  }
  taskscope_process_identity() {
    printf 'captured-identity'
  }
  taskscope_process_command() {
    printf '%s 30' "$rejected_executable"
  }
  taskscope_process_matches_identity() {
    return 0
  }
  taskscope_process_matches_executable() {
    return 0
  }
  taskscope_send_signal() {
    return 1
  }
  taskscope_pause() {
    return 0
  }

  if taskscope_stop_processes_for_executable "$rejected_executable" >/dev/null 2>&1; then
    echo "Guarded stop helper reported success after every signal was rejected." >&2
    exit 1
  fi
)

RELEASE_PUBLISH_LINE="$(
  /usr/bin/grep -nF 'mv "$OUTPUT_DIR" "$FINAL_DIR"' "$RELEASE_SCRIPT" \
    | /usr/bin/cut -d: -f1
)"
if [[ -z "$RELEASE_PUBLISH_LINE" ]]; then
  echo "Release script does not publish through the expected atomic move." >&2
  exit 1
fi
if /usr/bin/tail -n "+$((RELEASE_PUBLISH_LINE + 1))" "$RELEASE_SCRIPT" \
  | /usr/bin/grep -Eq '^[[:space:]]*(shasum|verify_[[:alnum:]_]+)'; then
  echo "Release script performs fallible artifact verification after publication." >&2
  exit 1
fi

FAKE_BIN="$TEST_DIR/bin"
SWIFT_MARKER="$TEST_DIR/swift-was-called"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/swift" <<EOF
#!/usr/bin/env bash
touch "$SWIFT_MARKER"
exit 99
EOF
chmod +x "$FAKE_BIN/swift"

if PATH="$FAKE_BIN:$PATH" "$BUILD_SCRIPT" --definitely-invalid >/dev/null 2>&1; then
  echo "Invalid build mode unexpectedly succeeded." >&2
  exit 1
fi
if [[ -e "$SWIFT_MARKER" ]]; then
  echo "Invalid build mode caused a build side effect." >&2
  exit 1
fi

rm -f "$SWIFT_MARKER"
if TASKSCOPE_BUNDLE_ID='invalid bundle id' PATH="$FAKE_BIN:$PATH" \
  "$BUILD_SCRIPT" --stage >/dev/null 2>&1; then
  echo "Invalid bundle identifier unexpectedly succeeded." >&2
  exit 1
fi
if [[ -e "$SWIFT_MARKER" ]]; then
  echo "Invalid bundle identifier caused a build side effect." >&2
  exit 1
fi

DISTRIBUTION_IDENTITY_OUTPUT="$TEST_DIR/distribution-identity.out"
rm -f "$SWIFT_MARKER"
if TASKSCOPE_BUNDLE_ID='com.example.TaskScopeTests' \
  TASKSCOPE_SIGNING_STYLE=distribution \
  TASKSCOPE_CODE_SIGN_IDENTITY=- \
  PATH="$FAKE_BIN:$PATH" "$BUILD_SCRIPT" --stage >/dev/null 2>"$DISTRIBUTION_IDENTITY_OUTPUT"; then
  echo "Distribution mode accepted a non-Developer-ID identity." >&2
  exit 1
fi
if ! /usr/bin/grep -Fq \
  'Distribution packaging requires an explicit Developer ID Application identity.' \
  "$DISTRIBUTION_IDENTITY_OUTPUT"; then
  echo "Distribution identity rejection did not reach the Developer ID check." >&2
  cat "$DISTRIBUTION_IDENTITY_OUTPUT" >&2
  exit 1
fi
if [[ -e "$SWIFT_MARKER" ]]; then
  echo "Invalid distribution identity caused a build side effect." >&2
  exit 1
fi

RELEASE_PREFLIGHT_OUTPUT="$TEST_DIR/release-preflight.out"
if TASKSCOPE_BUNDLE_ID='com.local.TaskScope' \
  "$RELEASE_SCRIPT" --preflight >"$RELEASE_PREFLIGHT_OUTPUT" 2>&1; then
  echo "Release preflight accepted the development bundle identifier." >&2
  exit 1
fi
if ! /usr/bin/grep -Fq \
  "Public releases cannot use the development bundle identifier 'com.local.TaskScope'." \
  "$RELEASE_PREFLIGHT_OUTPUT"; then
  echo "Release preflight did not reject the development bundle identifier." >&2
  cat "$RELEASE_PREFLIGHT_OUTPUT" >&2
  exit 1
fi
# Lifecycle evidence cases use a disposable repository, never invented passes
# in the real compatibility matrix or a managed GlobalProtect installation.
bash "$ROOT_DIR/script/test_release_compatibility.sh"

# The icon renders in a private directory: an AppIcon.iconset beside the output
# survives, and bad arguments or outputs fail with one line instead of a crash.
ICON_DIR="$TEST_DIR/Icon"
ICON_OUTPUT="$TEST_DIR/icon.out"
mkdir -p "$ICON_DIR/AppIcon.iconset" "$ICON_DIR/ReadOnly"
printf 'artwork\n' > "$ICON_DIR/AppIcon.iconset/source.psd"
swift "$ROOT_DIR/script/render_icon.swift" "$ICON_DIR/AppIcon.icns"
if [[ ! -s "$ICON_DIR/AppIcon.icns" ]] || ! grep -Fxq artwork "$ICON_DIR/AppIcon.iconset/source.psd"; then
  echo "Icon rendering replaced an existing AppIcon.iconset." >&2
  exit 1
fi
ICON_HELP="$(swift "$ROOT_DIR/script/render_icon.swift" --help)"
grep -q '^usage:' <<< "$ICON_HELP"
for icon_arguments in --bogus "$ICON_DIR/icon.png" "$ICON_DIR/one.icns $ICON_DIR/two.icns"; do
  icon_status=0
  # shellcheck disable=SC2086 # Each case is a list of arguments.
  swift "$ROOT_DIR/script/render_icon.swift" $icon_arguments > "$ICON_OUTPUT" 2>&1 || icon_status="$?"
  if [[ "$icon_status" -ne 2 ]] || ! grep -q '^usage:' "$ICON_OUTPUT"; then
    echo "Icon rendering accepted arguments: $icon_arguments" >&2
    cat "$ICON_OUTPUT" >&2
    exit 1
  fi
done
chmod a-w "$ICON_DIR/ReadOnly"
icon_status=0
swift "$ROOT_DIR/script/render_icon.swift" "$ICON_DIR/ReadOnly/AppIcon.icns" > "$ICON_OUTPUT" 2>&1 \
  || icon_status="$?"
chmod u+w "$ICON_DIR/ReadOnly"
if [[ "$icon_status" -ne 1 ]] || ! grep -q '^Icon rendering failed:' "$ICON_OUTPUT" \
  || grep -Eq 'Stack dump|Fatal error' "$ICON_OUTPUT"; then
  echo "An icon rendering failure was not reported as a one-line error." >&2
  cat "$ICON_OUTPUT" >&2
  exit 1
fi

# Package.swift alone sets the deployment target, enables complete concurrency
# checking for both targets, and defines the app target that packaging builds.
MANIFEST_FIXTURE="$TEST_DIR/Manifest"
MANIFEST_OUTPUT="$TEST_DIR/manifest.out"
mkdir -p "$MANIFEST_FIXTURE/Sources/TaskScope"
# Output is captured before grep -q: with pipefail, a writer that grep -q
# leaves early fails the pipeline with SIGPIPE even though the text matched.
for strict_target in TaskScope TaskScopeTests; do
  STRICT_TARGET_DESCRIPTION="$(taskscope_target_description "$ROOT_DIR" "$strict_target")"
  if ! grep -q '"StrictConcurrency"' <<< "$STRICT_TARGET_DESCRIPTION"; then
    echo "Package.swift does not enable complete concurrency checking for $strict_target." >&2
    exit 1
  fi
done
sed 's/\.macOS(\.v14)/.macOS("15.0")/' "$ROOT_DIR/Package.swift" > "$MANIFEST_FIXTURE/Package.swift"
grep -Fq '.macOS("15.0")' "$MANIFEST_FIXTURE/Package.swift"
if [[ "$(taskscope_minimum_system_version "$MANIFEST_FIXTURE")" != 15.0 ]]; then
  echo "Packaging ignored a changed Package.swift deployment target." >&2
  exit 1
fi
taskscope_prepare_application_package "$MANIFEST_FIXTURE" 15.0 >/dev/null
sed 's/\.executableTarget(name: "TaskScope"/.executableTarget(name: "TaskScope", exclude: ["Diverged"]/' \
  "$ROOT_DIR/Package.swift" > "$MANIFEST_FIXTURE/Package.swift"
grep -q 'Diverged' "$MANIFEST_FIXTURE/Package.swift"
if taskscope_prepare_application_package "$MANIFEST_FIXTURE" 14.0 > "$MANIFEST_OUTPUT" 2>&1; then
  echo "Packaging built an app target that differs from Package.swift." >&2
  exit 1
fi
grep -Fq 'declares the TaskScope target differently' "$MANIFEST_OUTPUT"

# Unchanged sources must build with identical compiler arguments, or SwiftPM
# recompiles the whole module, and a debug stage reuses the App Intents metadata
# while its inputs are unchanged. This fake swift records each build and creates
# the metadata file a build would write; package queries run the real swift.
METADATA_FIXTURE="$TEST_DIR/Metadata Fixture"
METADATA_BIN="$TEST_DIR/metadata-bin"
BUILD_LOG="$TEST_DIR/swift-builds"
mkdir -p "$METADATA_FIXTURE/script" "$METADATA_FIXTURE/Sources/TaskScope/Services" "$METADATA_BIN"
cp "$BUILD_SCRIPT" "$COMMON_SCRIPT" "$ROOT_DIR/script/render_icon.swift" "$METADATA_FIXTURE/script/"
cp "$ROOT_DIR/Package.swift" "$ROOT_DIR/LICENSE" "$ROOT_DIR/VERSION" "$ROOT_DIR/BUILD_NUMBER" "$METADATA_FIXTURE/"
cp "$ROOT_DIR/Sources/TaskScope/Services/TaskScopeIntents.swift" "$METADATA_FIXTURE/Sources/TaskScope/Services/"
cat > "$METADATA_BIN/swift" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == package ]]; then exec /usr/bin/swift "\$@"; fi
if [[ " \$* " == *" --show-bin-path "* ]]; then printf '%s\n' "$TEST_DIR/no-binary"; exit 0; fi
printf '%s\n' "\$*" >> "$BUILD_LOG"
previous=""
for argument in "\$@"; do
  [[ "\$previous" != -emit-const-values-path ]] || printf '{}\n' > "\$argument"
  [[ "\$argument" == -Xswiftc ]] || previous="\$argument"
done
EOF
chmod +x "$METADATA_BIN/swift"
run_metadata_stage() {
  # The stage stops at the missing binary, after every build has run.
  if PATH="$METADATA_BIN:$PATH" TASKSCOPE_BUNDLE_ID="$TEST_BUNDLE_ID" \
    TASKSCOPE_OUTPUT_DIR="$METADATA_FIXTURE/out" \
    bash "$METADATA_FIXTURE/script/build_and_run.sh" --stage > "$TEST_DIR/metadata.out" 2>&1; then
    echo "The metadata fixture unexpectedly staged a bundle." >&2
    exit 1
  fi
  grep -Fq "$TEST_DIR/no-binary/TaskScope" "$TEST_DIR/metadata.out" || {
    cat "$TEST_DIR/metadata.out" >&2
    exit 1
  }
}
: > "$BUILD_LOG"
run_metadata_stage
run_metadata_stage
if [[ "$(grep -c -- '-c release' "$BUILD_LOG")" -ne 2 ]] \
  || [[ "$(sed -n 1p "$BUILD_LOG")" != "$(sed -n 2p "$BUILD_LOG")" ]]; then
  echo "Unchanged sources produced different compiler arguments." >&2
  cat "$BUILD_LOG" >&2
  exit 1
fi
: > "$BUILD_LOG"
BUILD_CONFIGURATION=debug run_metadata_stage
if grep -q -- '-c release' "$BUILD_LOG" || ! grep -q -- '-c debug' "$BUILD_LOG"; then
  echo "A debug stage rebuilt release metadata for unchanged App Intents sources." >&2
  cat "$BUILD_LOG" >&2
  exit 1
fi
printf '// Changed intents source\n' >> "$METADATA_FIXTURE/Sources/TaskScope/Services/TaskScopeIntents.swift"
: > "$BUILD_LOG"
BUILD_CONFIGURATION=debug run_metadata_stage
grep -q -- '-c release' "$BUILD_LOG" || {
  echo "A debug stage reused App Intents metadata after its source changed." >&2
  exit 1
}

PACKAGE_LOCK="$TASKSCOPE_OUTPUT_DIR/.TaskScope.package.lock"
mkdir -p "$TASKSCOPE_OUTPUT_DIR"
/usr/bin/shlock -f "$PACKAGE_LOCK" -p "$$" || {
  echo "Another packaging process is running; rerun later ($PACKAGE_LOCK)." >&2
  exit 1
}
rm -f "$SWIFT_MARKER"
if TASKSCOPE_BUNDLE_ID='com.example.TaskScopeTests' PATH="$FAKE_BIN:$PATH" \
  "$BUILD_SCRIPT" --stage >/dev/null 2>&1; then
  echo "Packaging unexpectedly ignored an active packaging lock." >&2
  rm -f "$PACKAGE_LOCK"
  exit 1
fi
rm -f "$PACKAGE_LOCK"
if [[ -e "$SWIFT_MARKER" ]]; then
  echo "Packaging lock rejection caused a build side effect." >&2
  exit 1
fi

VERIFIED_COPY_DIR="$TEST_DIR/VerifiedCopy"
VERIFIED_COPY_BUNDLE="$VERIFIED_COPY_DIR/TaskScope.app"
mkdir -p "$VERIFIED_COPY_DIR"
TASKSCOPE_BUNDLE_ID="$TEST_BUNDLE_ID" \
  TASKSCOPE_VERIFIED_BUNDLE_COPY="$VERIFIED_COPY_BUNDLE" \
  "$BUILD_SCRIPT" --stage >/dev/null

STAGED_PLIST="$TASKSCOPE_OUTPUT_DIR/TaskScope.app/Contents/Info.plist"
STAGED_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGED_PLIST")"
if [[ "$STAGED_ID" != "$TEST_BUNDLE_ID" ]]; then
  echo "Staged bundle did not use the configured identifier." >&2
  exit 1
fi
VERIFIED_COPY_ID="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$VERIFIED_COPY_BUNDLE/Contents/Info.plist"
)"
if [[ "$VERIFIED_COPY_ID" != "$TEST_BUNDLE_ID" ]]; then
  echo "Lock-protected verified bundle copy has the wrong identifier." >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$VERIFIED_COPY_BUNDLE"
for stale_key in NSAppleEventsUsageDescription NSServerUsageDescription; do
  if /usr/libexec/PlistBuddy -c "Print :$stale_key" "$STAGED_PLIST" >/dev/null 2>&1; then
    echo "Staged bundle contains obsolete privacy key $stale_key." >&2
    exit 1
  fi
done

STAGED_APP="$TASKSCOPE_OUTPUT_DIR/TaskScope.app"
STAGED_BINARY="$STAGED_APP/Contents/MacOS/TaskScope"
# The hardened runtime keeps DYLD_INSERT_LIBRARIES out of the signed app,
# without entitlements outside a --debug build.
STAGED_SIGNATURE="$(/usr/bin/codesign -dvvv "$STAGED_APP" 2>&1)"
if ! /usr/bin/grep -Eq 'flags=.*runtime' <<< "$STAGED_SIGNATURE"; then
  echo "The staged app is signed without the hardened runtime." >&2
  exit 1
fi
STAGED_ENTITLEMENTS="$(/usr/bin/codesign -d --entitlements - --xml "$STAGED_APP" 2>/dev/null || true)"
if /usr/bin/grep -q '<key>' <<< "$STAGED_ENTITLEMENTS"; then
  echo "The staged app carries entitlements." >&2
  exit 1
fi
# No search path into the build machine's toolchain survives in the app.
taskscope_verify_binary_paths "$STAGED_BINARY"
# The plist, the binary's minimum OS, and Package.swift agree.
PACKAGE_MINIMUM="$(taskscope_minimum_system_version "$ROOT_DIR")"
STAGED_BUILD_VERSION="$(/usr/bin/vtool -show-build "$STAGED_BINARY")"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$STAGED_PLIST")" != "$PACKAGE_MINIMUM" ]] \
  || ! /usr/bin/grep -Eq "minos[[:space:]]+$PACKAGE_MINIMUM\$" <<< "$STAGED_BUILD_VERSION"; then
  echo "The staged deployment target differs from Package.swift ($PACKAGE_MINIMUM)." >&2
  exit 1
fi
for plist_entry in CFBundleInfoDictionaryVersion=6.0 CFBundleDevelopmentRegion=en \
  LSApplicationCategoryType=public.app-category.utilities \
  "NSHumanReadableCopyright=$(taskscope_copyright_notice "$ROOT_DIR")"; do
  if [[ "$(/usr/libexec/PlistBuddy -c "Print :${plist_entry%%=*}" "$STAGED_PLIST" 2>/dev/null)" \
    != "${plist_entry#*=}" ]]; then
    echo "The staged Info.plist lacks ${plist_entry%%=*} = ${plist_entry#*=}." >&2
    exit 1
  fi
done
# Packaging builds the app-only package, which resolves no dependencies.
if /usr/bin/grep -q ViewInspector "$ROOT_DIR/.build/taskscope-application/.build/workspace-state.json" 2>/dev/null \
  || [[ -e "$ROOT_DIR/.build/taskscope-application/.build/checkouts/ViewInspector" ]]; then
  echo "Packaging resolved the test-only ViewInspector dependency." >&2
  exit 1
fi

TASKSCOPE_BUNDLE_ID="$TEST_BUNDLE_ID" "$BUILD_SCRIPT" --verify >/dev/null
assert_no_test_preferences

# A startup check launches the staged bundle. It must leave no duplicate
# launcher registration even though the build folder is excluded from metadata.
swift - "$TASKSCOPE_OUTPUT_DIR/TaskScope.app" "$TEST_BUNDLE_ID" <<'SWIFT'
import AppKit
let stagedPath = CommandLine.arguments[1]
let bundleID = CommandLine.arguments[2]
if NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).contains(where: { $0.path == stagedPath }) {
    print("Startup verification left the staged app registered with Launch Services.")
    exit(1)
}
SWIFT

DEST_DIR="$TEST_DIR/Applications" TASKSCOPE_BUNDLE_ID="$TEST_BUNDLE_ID" \
  "$INSTALL_SCRIPT" --no-open >/dev/null 2>&1 && {
  echo "Install unexpectedly accepted a missing destination." >&2
  exit 1
}

TEST_APPLICATIONS="$TEST_DIR/Applications"
mkdir -p "$TEST_APPLICATIONS"
INSTALL_LOCK="$TEST_APPLICATIONS/.TaskScope.install.lock"
/usr/bin/shlock -f "$INSTALL_LOCK" -p "$$"
if DEST_DIR="$TEST_APPLICATIONS" TASKSCOPE_SKIP_BUILD=1 \
  TASKSCOPE_BUNDLE_ID="$TEST_BUNDLE_ID" \
  "$INSTALL_SCRIPT" --no-open >/dev/null 2>&1; then
  echo "Installer unexpectedly ignored an active destination lock." >&2
  rm -f "$INSTALL_LOCK"
  exit 1
fi
rm -f "$INSTALL_LOCK"
if [[ -e "$TEST_APPLICATIONS/TaskScope.app" ]]; then
  echo "Rejected concurrent installer changed the destination." >&2
  exit 1
fi

DEST_DIR="$TEST_APPLICATIONS" TASKSCOPE_SKIP_BUILD=1 \
  TASKSCOPE_BUNDLE_ID="$TEST_BUNDLE_ID" \
  "$INSTALL_SCRIPT" --no-open >/dev/null

INSTALLED_BUNDLE="$TEST_APPLICATIONS/TaskScope.app"
INSTALLED_PLIST="$INSTALLED_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 777" "$INSTALLED_PLIST"
/usr/bin/codesign --force --deep --sign - "$INSTALLED_BUNDLE" >/dev/null

for failure_point in after_copy after_backup after_replace after_verify; do
  if DEST_DIR="$TEST_APPLICATIONS" TASKSCOPE_SKIP_BUILD=1 \
    TASKSCOPE_BUNDLE_ID="$TEST_BUNDLE_ID" \
    TASKSCOPE_INSTALL_FAIL_AT="$failure_point" \
    "$INSTALL_SCRIPT" --no-open >/dev/null 2>&1; then
    echo "Injected install failure at $failure_point unexpectedly succeeded." >&2
    exit 1
  fi

  RESTORED_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INSTALLED_PLIST")"
  if [[ "$RESTORED_BUILD" != "777" ]]; then
    echo "Rollback at $failure_point did not restore the previous app bundle." >&2
    exit 1
  fi
done
/usr/bin/codesign --verify --deep --strict "$INSTALLED_BUNDLE"

if DEST_DIR="$TEST_APPLICATIONS" TASKSCOPE_SKIP_BUILD=1 \
  TASKSCOPE_BUNDLE_ID='com.example.DifferentTaskScope' \
  "$INSTALL_SCRIPT" --no-open >/dev/null 2>&1; then
  echo "Installer accepted a staged bundle identifier mismatch." >&2
  exit 1
fi

FOREIGN_APPLICATIONS="$TEST_DIR/ForeignApplications"
mkdir -p "$FOREIGN_APPLICATIONS"
/usr/bin/ditto "$INSTALLED_BUNDLE" "$FOREIGN_APPLICATIONS/TaskScope.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.example.ForeignApp' \
  "$FOREIGN_APPLICATIONS/TaskScope.app/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "$FOREIGN_APPLICATIONS/TaskScope.app" >/dev/null
if DEST_DIR="$FOREIGN_APPLICATIONS" TASKSCOPE_SKIP_BUILD=1 \
  TASKSCOPE_BUNDLE_ID="$TEST_BUNDLE_ID" \
  "$INSTALL_SCRIPT" --no-open >/dev/null 2>&1; then
  echo "Installer replaced an unrelated existing application." >&2
  exit 1
fi

for failure_point in after_copy after_backup after_replace after_verify; do
  FRESH_APPLICATIONS="$TEST_DIR/Fresh-$failure_point"
  mkdir -p "$FRESH_APPLICATIONS"
  if DEST_DIR="$FRESH_APPLICATIONS" TASKSCOPE_SKIP_BUILD=1 \
    TASKSCOPE_BUNDLE_ID="$TEST_BUNDLE_ID" \
    TASKSCOPE_INSTALL_FAIL_AT="$failure_point" \
    "$INSTALL_SCRIPT" --no-open >/dev/null 2>&1; then
    echo "Fresh install failure at $failure_point unexpectedly succeeded." >&2
    exit 1
  fi
  if [[ -e "$FRESH_APPLICATIONS/TaskScope.app" ]]; then
    echo "Fresh install failure at $failure_point left an application behind." >&2
    exit 1
  fi
done

if find "$TEST_APPLICATIONS" -maxdepth 1 \
  \( -name '.TaskScope.installing.*' -o -name '.TaskScope.backup.*' \
    -o -name '.TaskScope.install.lock*' \) -print -quit | grep -q .; then
  echo "Installer left transaction artifacts behind." >&2
  exit 1
fi

"$BUILD_SCRIPT" --stage >/dev/null
DEFAULT_STAGED_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGED_PLIST")"
if [[ "$DEFAULT_STAGED_ID" != 'com.local.TaskScope' ]]; then
  echo "Default packaging no longer uses the development bundle identifier." >&2
  exit 1
fi

if [[ "$(checkout_state)" != "$CHECKOUT_STATE" ]]; then
  echo "Packaging tests changed the checkout's staged bundle or Package.resolved." >&2
  exit 1
fi

PACKAGING_TESTS_FINISHED=1
echo "Packaging tests passed."
