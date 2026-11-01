#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  ""|--packaging-only|--evidence-only) ;;
  *) echo "usage: $0 [--packaging-only|--evidence-only]" >&2; exit 2 ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/taskscope-release-evidence.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

FIXTURE_DIR="$TEST_DIR/release fixture"
FAKE_BIN="$TEST_DIR/bin"
TOOL_LOG="$TEST_DIR/tool-calls"
OUTPUT="$TEST_DIR/output"
EVIDENCE_RELATIVE='Evidence/GlobalProtect/lifecycle/1.2.3-7'
EVIDENCE_DIR="$FIXTURE_DIR/$EVIDENCE_RELATIVE"
MANIFEST="$EVIDENCE_DIR/arm64.evidence"
CHECKS=0
# Exercise only the swap section with fake process and file operations. Never
# build, signal a real process, or launch an app in these regression cases.
test_staging_stops_before_swap() (
  local swap_script
  local MODE
  local running
  local swaps
  local APP_BUNDLE="$TEST_DIR/staged.app"
  local OUTPUT_BACKUP="$TEST_DIR/backup.app"
  local STAGING_BUNDLE="$TEST_DIR/new.app"
  mkdir -p "$APP_BUNDLE"
  swap_script="$(awk '
    /^verify_bundle "\$STAGING_BUNDLE"$/ { copying = 1; next }
    copying { print }
    copying && /^rm -rf "\$OUTPUT_BACKUP"$/ { exit }
  ' "$ROOT_DIR/script/build_and_run.sh")"
  [[ -n "$swap_script" ]] || exit 1
  stop_staged_app_instances() { running=0; }
  mv() {
    [[ "$running" -eq 0 ]] || {
      echo "Bundle swap orphaned a running instance in mode $MODE." >&2
      exit 1
    }
    swaps=$((swaps + 1))
  }
  rm() { :; }
  for MODE in run --stage stage --debug debug --logs logs --telemetry telemetry; do
    running=1
    swaps=0
    eval "$swap_script"
    [[ "$running" -eq 0 && "$swaps" -eq 2 ]] || exit 1
  done
)

test_packaging_environment_isolation() (
  local name
  local inputs=(TASKSCOPE_BUNDLE_ID TASKSCOPE_SIGNING_STYLE TASKSCOPE_CODE_SIGN_IDENTITY
    TASKSCOPE_VERIFIED_BUNDLE_COPY TASKSCOPE_INSTALL_FAIL_AT TASKSCOPE_SKIP_BUILD
    TASKSCOPE_RELEASE_ARCHS TASKSCOPE_EXPECTED_TEAM_ID TASKSCOPE_NOTARY_KEYCHAIN_PROFILE
    BUILD_CONFIGURATION)
  for name in "${inputs[@]}"; do
    export "$name=inherited-release-value"
  done
  # Stop before any test setup or real packaging operations.
  eval "$(awk '/^ROOT_DIR=/ { exit } { print }' "$ROOT_DIR/script/test_packaging.sh")"
  for name in "${inputs[@]}"; do
    [[ -z "${!name:-}" ]] || {
      echo "Packaging tests inherited $name." >&2
      exit 1
    }
  done
  source "$ROOT_DIR/script/packaging_common.sh"
  [[ "$(taskscope_resolve_bundle_id)" == com.local.TaskScope ]]
)

test_build_number_history() (
  source "$ROOT_DIR/script/packaging_common.sh"
  local fixture_tags=''
  local release_build=9
  local hotfix_build=12
  local prerelease_build=8
  local candidate
  # Git history is supplied by a fake; this test never creates or changes tags.
  git() {
    case "$3" in
      tag) printf '%s' "$fixture_tags" ;;
      show)
        case "$4" in
          v1.1.0:BUILD_NUMBER) printf '%s\n' "$release_build" ;;
          v1.0.1:BUILD_NUMBER) printf '%s\n' "$hotfix_build" ;;
          v1.1.0-rc1:BUILD_NUMBER) printf '%s\n' "$prerelease_build" ;;
          *) return 1 ;;
        esac
        ;;
      *) return 1 ;;
    esac
  }
  taskscope_validate_build_number_history "$TEST_DIR" 1
  # The lower-version hotfix has the maximum build, independent of tag order.
  fixture_tags=$'v1.1.0-rc1\nv1.1.0\nv1.0.1'
  taskscope_validate_build_number_history "$TEST_DIR" 13
  for candidate in 9 11 12; do
    if taskscope_validate_build_number_history "$TEST_DIR" "$candidate" > "$OUTPUT" 2>&1; then
      echo "Release accepted reused build $candidate." >&2
      exit 1
    fi
    grep -Fq 'value at v1.0.1 (12)' "$OUTPUT"
  done
  # A prerelease sorted above the final tag must not hide the final build.
  fixture_tags=$'v1.1.0-rc1\nv1.1.0'
  if taskscope_validate_build_number_history "$TEST_DIR" 9 > "$OUTPUT" 2>&1; then
    exit 1
  fi
  grep -Fq 'value at v1.1.0 (9)' "$OUTPUT"
  taskscope_validate_build_number_history "$TEST_DIR" 10
  for release_build in '' invalid 0 01; do
    if taskscope_validate_build_number_history "$TEST_DIR" 13 > "$OUTPUT" 2>&1; then
      echo "Release accepted invalid tagged BUILD_NUMBER '$release_build'." >&2
      exit 1
    fi
    grep -Fq 'Invalid BUILD_NUMBER at v1.1.0' "$OUTPUT"
  done
  release_build=99999999999999999999
  if taskscope_validate_build_number_history "$TEST_DIR" "$release_build" > "$OUTPUT" 2>&1; then
    exit 1
  fi
  grep -Fq "value at v1.1.0 ($release_build)" "$OUTPUT"
  taskscope_validate_build_number_history "$TEST_DIR" 100000000000000000000
  fixture_tags=v0.9.0
  if taskscope_validate_build_number_history "$TEST_DIR" 13 > "$OUTPUT" 2>&1; then
    exit 1
  fi
  grep -Fq 'Could not read BUILD_NUMBER at v0.9.0.' "$OUTPUT"
  git() { return 1; }
  if taskscope_validate_build_number_history "$TEST_DIR" 13 > "$OUTPUT" 2>&1; then
    exit 1
  fi
  grep -Fq 'Could not list release tags.' "$OUTPUT"
)

test_launch_refuses_other_bundle_path() (
  local launch_script
  local mode
  local kind
  local kind_path
  local harness="$TEST_DIR/launch-harness.sh"
  local bundle="$TEST_DIR/Launch Target.app"
  local other_bundle="$TEST_DIR/Already Running.app"
  mkdir -p "$bundle" "$other_bundle"
  cat > "$harness" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$ROOT_DIR/script/packaging_common.sh"
APP_BUNDLE="$TARGET_BUNDLE"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/TaskScope"
APP_NAME=TaskScope
DEST_BUNDLE="$TARGET_BUNDLE"
OPEN_AFTER_INSTALL=1
BUNDLE_ID=com.example.TaskScopeTests
taskscope_running_bundle_paths() {
  [[ "${INVENTORY_FAILED:-0}" -eq 0 ]] || return 1
  if [[ "$1" == "$RUNNING_ID" ]]; then
    printf '4242\t%s\n' "$RUNNING_PATH"
  fi
}
taskscope_process_runs_bundle_executable() { [[ "${STALE_EXECUTABLE:-0}" -eq 0 ]]; }
taskscope_stop_processes_for_executable() { printf 'unexpected stop\n' >> "$TOOL_LOG"; return 1; }
taskscope_send_signal() { printf 'unexpected signal\n' >> "$TOOL_LOG"; return 1; }
function /usr/bin/open() { printf 'open %s\n' "$*" >> "$TOOL_LOG"; }
function /usr/bin/log() { printf 'log %s\n' "$*" >> "$TOOL_LOG"; }
lldb() { printf 'lldb %s\n' "$*" >> "$TOOL_LOG"; }
eval "$LAUNCH_SCRIPT"
EOF
  for kind in build install; do
    if [[ "$kind" == build ]]; then
      launch_script="$(awk '/^open_app\(\)/ { copying = 1 } copying { print }' "$ROOT_DIR/script/build_and_run.sh")"
    else
      launch_script="$(awk '/^if \[\[ "\$OPEN_AFTER_INSTALL"/ { copying = 1 } copying { print }' "$ROOT_DIR/script/install.sh")"
    fi
    [[ -n "$launch_script" ]] || exit 1
    for mode in run --logs logs --telemetry telemetry --debug debug; do
      : > "$TOOL_LOG"
      if ROOT_DIR="$ROOT_DIR" TARGET_BUNDLE="$bundle" MODE="$mode" \
        RUNNING_PATH="$other_bundle" RUNNING_ID=com.example.TaskScopeTests \
        LAUNCH_SCRIPT="$launch_script" TOOL_LOG="$TOOL_LOG" \
        bash "$harness" > "$OUTPUT" 2>&1; then
        echo "$kind $mode launched beside a running same-ID bundle." >&2
        exit 1
      fi
      [[ ! -s "$TOOL_LOG" ]] || { cat "$TOOL_LOG" >&2; exit 1; }
      grep -Fq "$other_bundle" "$OUTPUT"
      grep -Fq 'Quit that copy' "$OUTPUT"
    done
    # The same canonical path and a different bundle ID remain launchable.
    for kind_path in "$bundle" "$other_bundle"; do
      local running_id=com.example.TaskScopeTests
      [[ "$kind_path" == "$bundle" ]] || running_id=com.example.Other
      : > "$TOOL_LOG"
      ROOT_DIR="$ROOT_DIR" TARGET_BUNDLE="$bundle" MODE=run \
        RUNNING_PATH="$kind_path" RUNNING_ID="$running_id" \
        LAUNCH_SCRIPT="$launch_script" TOOL_LOG="$TOOL_LOG" \
        bash "$harness" > "$OUTPUT" 2>&1
      grep -Fxq "open $bundle" "$TOOL_LOG" || {
        echo "$kind did not open the target without forcing a new instance." >&2
        exit 1
      }
    done
    # A same-path copy whose executable was replaced is a stale build; `open`
    # would only activate it, so launching must refuse instead.
    : > "$TOOL_LOG"
    if ROOT_DIR="$ROOT_DIR" TARGET_BUNDLE="$bundle" MODE=run \
      RUNNING_PATH="$bundle" RUNNING_ID=com.example.TaskScopeTests STALE_EXECUTABLE=1 \
      LAUNCH_SCRIPT="$launch_script" TOOL_LOG="$TOOL_LOG" \
      bash "$harness" > "$OUTPUT" 2>&1; then
      echo "$kind launched beside a stale build of the same bundle." >&2
      exit 1
    fi
    [[ ! -s "$TOOL_LOG" ]] || { cat "$TOOL_LOG" >&2; exit 1; }
    grep -Fq 'older build' "$OUTPUT"
    : > "$TOOL_LOG"
    if ROOT_DIR="$ROOT_DIR" TARGET_BUNDLE="$bundle" MODE=run \
      RUNNING_PATH="$other_bundle" RUNNING_ID=com.example.TaskScopeTests INVENTORY_FAILED=1 \
      LAUNCH_SCRIPT="$launch_script" TOOL_LOG="$TOOL_LOG" \
      bash "$harness" > "$OUTPUT" 2>&1; then
      echo "$kind launched after running-app lookup failed." >&2
      exit 1
    fi
    [[ ! -s "$TOOL_LOG" ]] || exit 1
    grep -Fq 'Could not check running TaskScope applications' "$OUTPUT"
  done
)

test_verify_holds_packaging_lock() (
  local flow
  local mode
  local fixture="$TEST_DIR/verify fixture"
  local harness="$TEST_DIR/verify-harness.sh"
  mkdir -p "$fixture/dist/build.noindex/TaskScope.app"
  # Execute the production --verify dispatch and lock/cleanup setup, stopping
  # before any build work. Both verification operations and shlock are fakes.
  flow="$(awk '
    /^stop_staged_app_instances\(\)/ { in_function = 1 }
    in_function && /^}$/ { copying = 1; in_function = 0; next }
    /^METADATA_WORK_DIR="\$\(mktemp/ { exit }
    copying { print }
  ' "$ROOT_DIR/script/build_and_run.sh")"
  cat > "$harness" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DIST_DIR="$ROOT_DIR/dist/build.noindex"
APP_NAME=TaskScope
APP_BUNDLE="$DIST_DIR/TaskScope.app"
function /usr/bin/shlock() {
  [[ ! -e "$2" ]] || return 1
  printf '%s\n' "$4" > "$2"
}
verify_bundle() {
  [[ -f "$DIST_DIR/.TaskScope.package.lock" ]] || {
    echo 'Static verification read the staged bundle without the packaging lock.' >&2
    return 1
  }
  printf 'static\n' >> "$TOOL_LOG"
}
verify_startup_readiness() {
  if /usr/bin/shlock -f "$DIST_DIR/.TaskScope.package.lock" -p competing-stager; then
    echo 'Concurrent restaging acquired the lock during startup verification.' >&2
    return 1
  fi
  printf 'startup\n' >> "$TOOL_LOG"
  [[ "${FAIL_STARTUP:-0}" -eq 0 ]]
}
eval "$VERIFY_FLOW"
EOF
  for mode in --verify verify; do
    : > "$TOOL_LOG"
    if ! ROOT_DIR="$fixture" MODE="$mode" VERIFY_FLOW="$flow" TOOL_LOG="$TOOL_LOG" \
      bash "$harness" > "$OUTPUT" 2>&1; then
      cat "$OUTPUT" >&2
      exit 1
    fi
    [[ "$(cat "$TOOL_LOG")" == $'static\nstartup' ]] || exit 1
    [[ ! -e "$fixture/dist/build.noindex/.TaskScope.package.lock" ]] || exit 1
    printf 'other-owner\n' > "$fixture/dist/build.noindex/.TaskScope.package.lock"
    : > "$TOOL_LOG"
    if ROOT_DIR="$fixture" MODE="$mode" VERIFY_FLOW="$flow" TOOL_LOG="$TOOL_LOG" \
      bash "$harness" > "$OUTPUT" 2>&1; then
      echo 'Verification ignored an existing packaging lock.' >&2
      exit 1
    fi
    [[ ! -s "$TOOL_LOG" ]] || exit 1
    grep -Fq 'Another TaskScope packaging process owns' "$OUTPUT"
    grep -Fxq 'other-owner' "$fixture/dist/build.noindex/.TaskScope.package.lock"
    rm "$fixture/dist/build.noindex/.TaskScope.package.lock"
    if ROOT_DIR="$fixture" MODE="$mode" VERIFY_FLOW="$flow" TOOL_LOG="$TOOL_LOG" FAIL_STARTUP=1 \
      bash "$harness" > "$OUTPUT" 2>&1; then
      echo 'Verification ignored a startup failure.' >&2
      exit 1
    fi
    [[ ! -e "$fixture/dist/build.noindex/.TaskScope.package.lock" ]] || exit 1
  done
)

test_install_locks_and_rechecks_copy() (
  local definitions
  local flow
  local skip_build
  local key
  local fixture="$TEST_DIR/install fixture"
  local harness="$TEST_DIR/install-harness.sh"
  local common="$ROOT_DIR/script/packaging_common.sh"
  definitions="$(awk '/^cleanup_install\(\)/ { copying = 1 } /^if \[\[ ! -d "\$DEST_DIR"/ { exit } copying { print }' "$ROOT_DIR/script/install.sh")"
  flow="$(awk '/^if \[\[ ! -d "\$DEST_DIR"/ { copying = 1 } copying { print }' "$ROOT_DIR/script/install.sh")"
  mkdir -p "$fixture/script"
  # The installer's optional stage child is only this inert mock.
  printf '#!/usr/bin/env bash\nprintf "stage\\n" >> "$TOOL_LOG"\n' > "$fixture/script/build_and_run.sh"
  chmod +x "$fixture/script/build_and_run.sh"
  printf '1.2.3\n' > "$fixture/VERSION"
  printf '7\n' > "$fixture/BUILD_NUMBER"
  cat > "$harness" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$COMMON_SCRIPT"
APP_NAME=TaskScope
BUNDLE_ID=com.example.TaskScopeTests
OPEN_AFTER_INSTALL=0
DEST_DIR="$ROOT_DIR/Applications"
DEST_BUNDLE="$DEST_DIR/TaskScope.app"
STAGED_BUNDLE="$ROOT_DIR/dist/build.noindex/TaskScope.app"
INSTALLING_BUNDLE="$DEST_DIR/.TaskScope.installing.$$"
BACKUP_BUNDLE="$DEST_DIR/.TaskScope.backup.$$"
INSTALL_LOCK="$DEST_DIR/.TaskScope.install.lock"
PACKAGING_LOCK="$ROOT_DIR/dist/build.noindex/.TaskScope.package.lock"
INSTALL_LOCK_ACQUIRED=0
PACKAGING_LOCK_ACQUIRED=0
INSTALL_STATE=preparing
mkdir -p "$DEST_DIR" "$STAGED_BUNDLE/Contents"
printf 'CFBundleIdentifier=%s\nCFBundleShortVersionString=1.2.3\nCFBundleVersion=7\n' \
  "$BUNDLE_ID" > "$STAGED_BUNDLE/Contents/Info.plist"
function /usr/bin/shlock() {
  [[ ! -e "$2" ]] || return 1
  printf '%s\n' "$4" > "$2"
}
function /usr/libexec/PlistBuddy() {
  local key="${2#Print :}"
  awk -F= -v key="$key" '$1 == key { print $2 }' "$3"
}
function /usr/bin/codesign() {
  local bundle="${@: -1}"
  if [[ "$bundle" == "$STAGED_BUNDLE" || "$bundle" == "$INSTALLING_BUNDLE" ]]; then
    [[ -e "$PACKAGING_LOCK" ]] || {
      echo 'Installer validated the staged bundle or copy without the packaging lock.' >&2
      return 1
    }
  fi
  printf 'verify %s\n' "$bundle" >> "$TOOL_LOG"
}
function /usr/bin/ditto() {
  [[ -e "$PACKAGING_LOCK" ]] || {
    echo 'Installer copied without the packaging lock.' >&2
    return 1
  }
  if /usr/bin/shlock -f "$PACKAGING_LOCK" -p competing-stager; then
    echo 'Concurrent restaging acquired the lock during install copying.' >&2
    return 1
  fi
  cp -R "$1" "$2"
  if [[ -n "${CORRUPT_KEY:-}" ]]; then
    awk -F= -v key="$CORRUPT_KEY" '$1 == key { $0 = key "=substituted" } { print }' \
      "$2/Contents/Info.plist" > "$2/Contents/changed"
    mv "$2/Contents/changed" "$2/Contents/Info.plist"
  fi
}
eval "$INSTALL_DEFINITIONS"
stop_destination_app() { printf 'stop-destination\n' >> "$TOOL_LOG"; }
eval "$INSTALL_FLOW"
EOF
  for skip_build in 1 0; do
    : > "$TOOL_LOG"
    if ! ROOT_DIR="$fixture" COMMON_SCRIPT="$common" \
      INSTALL_DEFINITIONS="$definitions" INSTALL_FLOW="$flow" TOOL_LOG="$TOOL_LOG" \
      TASKSCOPE_SKIP_BUILD="$skip_build" bash "$harness" > "$OUTPUT" 2>&1; then
      cat "$OUTPUT" >&2
      exit 1
    fi
    [[ -f "$fixture/Applications/TaskScope.app/Contents/Info.plist" ]] || exit 1
    [[ ! -e "$fixture/dist/build.noindex/.TaskScope.package.lock" ]] || exit 1
    for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion; do
      : > "$TOOL_LOG"
      if ROOT_DIR="$fixture" COMMON_SCRIPT="$common" \
        INSTALL_DEFINITIONS="$definitions" INSTALL_FLOW="$flow" TOOL_LOG="$TOOL_LOG" \
        TASKSCOPE_SKIP_BUILD="$skip_build" CORRUPT_KEY="$key" \
        bash "$harness" > "$OUTPUT" 2>&1; then
        echo "Installer accepted a copied bundle with substituted $key." >&2
        exit 1
      fi
      grep -Fq "$key" "$OUTPUT"
      if grep -Fq stop-destination "$TOOL_LOG"; then
        echo 'Invalid install copy stopped the existing destination app.' >&2
        exit 1
      fi
      grep -Fxq 'CFBundleVersion=7' "$fixture/Applications/TaskScope.app/Contents/Info.plist"
      [[ ! -e "$fixture/dist/build.noindex/.TaskScope.package.lock" ]] || exit 1
      [[ ! -e "$fixture/Applications/.TaskScope.install.lock" ]] || exit 1
    done
    printf 'other-owner\n' > "$fixture/dist/build.noindex/.TaskScope.package.lock"
    : > "$TOOL_LOG"
    if ROOT_DIR="$fixture" COMMON_SCRIPT="$common" \
      INSTALL_DEFINITIONS="$definitions" INSTALL_FLOW="$flow" TOOL_LOG="$TOOL_LOG" \
      TASKSCOPE_SKIP_BUILD="$skip_build" bash "$harness" > "$OUTPUT" 2>&1; then
      echo 'Installer ignored an existing packaging lock.' >&2
      exit 1
    fi
    grep -Fq 'Another TaskScope packaging process owns' "$OUTPUT"
    grep -Fxq 'other-owner' "$fixture/dist/build.noindex/.TaskScope.package.lock"
    [[ ! -e "$fixture/Applications/.TaskScope.install.lock" ]] || exit 1
    rm "$fixture/dist/build.noindex/.TaskScope.package.lock"
  done
)

test_packaging_preferences_cleanup() (
  local definitions
  local leak
  local status
  local fixture="$TEST_DIR/preferences fixture"
  local harness="$TEST_DIR/preferences-harness.sh"
  definitions="$(awk '
    /^assert_no_test_preferences\(\)/ || /^cleanup_test\(\)/ { copying = 1 }
    /^trap cleanup_test EXIT/ { exit }
    copying { print }
  ' "$ROOT_DIR/script/test_packaging.sh")"
  cat > "$harness" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
TEST_DIR="$FIXTURE/work"
TEST_PREFERENCES_DIR="$FIXTURE/preferences"
TEST_BUNDLE_ID=com.example.TaskScopeTests.MockCleanup
mkdir -p "$TEST_DIR" "$TEST_PREFERENCES_DIR/ByHost"
function /usr/bin/defaults() { printf 'defaults %s\n' "$*" >> "$TOOL_LOG"; }
eval "$CLEANUP_DEFINITIONS"
trap cleanup_test EXIT
case "$LEAK" in
  main) printf 'synthetic preferences\n' > "$TEST_PREFERENCES_DIR/$TEST_BUNDLE_ID.plist" ;;
  byhost) printf 'synthetic preferences\n' > "$TEST_PREFERENCES_DIR/ByHost/$TEST_BUNDLE_ID.fake-host.plist" ;;
esac
exit "${TEST_EXIT:-0}"
EOF
  for leak in main byhost none; do
    : > "$TOOL_LOG"
    status=0
    FIXTURE="$fixture" CLEANUP_DEFINITIONS="$definitions" TOOL_LOG="$TOOL_LOG" LEAK="$leak" \
      bash "$harness" > "$OUTPUT" 2>&1 || status="$?"
    if find "$fixture/preferences" -name '*.plist' -print -quit | grep -q .; then
      echo 'Packaging cleanup left test preferences outside its temporary directory.' >&2
      exit 1
    fi
    [[ ! -d "$fixture/work" ]] || exit 1
    grep -Fxq 'defaults delete com.example.TaskScopeTests.MockCleanup' "$TOOL_LOG"
    if [[ "$leak" == none ]]; then
      [[ "$status" -eq 0 ]] || { cat "$OUTPUT" >&2; exit 1; }
    else
      [[ "$status" -ne 0 ]] || { echo 'Packaging accepted escaped preferences.' >&2; exit 1; }
      grep -Fq 'Startup verification wrote preferences outside' "$OUTPUT"
    fi
  done
  status=0
  FIXTURE="$fixture" CLEANUP_DEFINITIONS="$definitions" TOOL_LOG="$TOOL_LOG" LEAK=none TEST_EXIT=31 \
    bash "$harness" > "$OUTPUT" 2>&1 || status="$?"
  [[ "$status" -eq 31 ]] || { echo 'Packaging cleanup hid an earlier test failure.' >&2; exit 1; }
)

if [[ "${1:-}" != --evidence-only ]]; then
  test_packaging_preferences_cleanup
  test_install_locks_and_rechecks_copy
  test_verify_holds_packaging_lock
  test_launch_refuses_other_bundle_path
  test_staging_stops_before_swap
  test_packaging_environment_isolation
  test_build_number_history
  echo 'Packaging regression tests passed (7 groups: preferences, install, verification, launch, staging, environment, build history).'
fi
[[ "${1:-}" != --packaging-only ]] || exit 0

mkdir -p "$FIXTURE_DIR/script" "$FIXTURE_DIR/Sources" "$EVIDENCE_DIR" "$FAKE_BIN"
cp "$ROOT_DIR/script/release.sh" "$ROOT_DIR/script/packaging_common.sh" "$FIXTURE_DIR/script/"
printf '1.2.3\n' > "$FIXTURE_DIR/VERSION"
printf '7\n' > "$FIXTURE_DIR/BUILD_NUMBER"
printf '## [1.2.3] - 2026-09-26\n' > "$FIXTURE_DIR/CHANGELOG.md"
printf 'tested candidate\n' > "$FIXTURE_DIR/Sources/candidate.txt"
git init -q -b main "$FIXTURE_DIR"
git -C "$FIXTURE_DIR" config user.name 'Packaging Tests'
git -C "$FIXTURE_DIR" config user.email 'packaging-tests@example.invalid'
git -C "$FIXTURE_DIR" config commit.gpgsign false
git -C "$FIXTURE_DIR" config core.hooksPath /dev/null
git -C "$FIXTURE_DIR" add .
git -C "$FIXTURE_DIR" commit -qm 'Synthetic candidate; not compatibility evidence'
TESTED_REVISION="$(git -C "$FIXTURE_DIR" rev-parse HEAD)"

# Tool discovery is allowed only after evidence passes. Any attempted build,
# signing, or notary operation is a test failure, without using credentials.
cat > "$FAKE_BIN/release-tool" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$TOOL_LOG"
[[ "${0##*/}" == xcrun && "${1:-}" == --find ]] && exit 0
exit 91
EOF
chmod +x "$FAKE_BIN/release-tool"
for tool in codesign ditto dwarfdump lipo plutil security shasum shlock spctl swift xcodebuild xcrun; do
  ln -s release-tool "$FAKE_BIN/$tool"
done

run_release() {
  : > "$TOOL_LOG"
  (
    unset TASKSCOPE_CODE_SIGN_IDENTITY TASKSCOPE_EXPECTED_TEAM_ID TASKSCOPE_NOTARY_KEYCHAIN_PROFILE
    cd "$TEST_DIR" # The gate must resolve evidence independently of the caller cwd.
    TASKSCOPE_BUNDLE_ID=com.example.TaskScopeTests TASKSCOPE_RELEASE_ARCHS=arm64 \
      TOOL_LOG="$TOOL_LOG" PATH="$FAKE_BIN:$PATH" \
      bash "$FIXTURE_DIR/script/release.sh" "$@"
  ) > "$OUTPUT" 2>&1
}

assert_failure() {
  local expected="$1"
  local mode="${2:---preflight}"
  if run_release "$mode"; then
    echo "Release $mode unexpectedly accepted: $expected" >&2
    cat "$OUTPUT" >&2
    exit 1
  fi
  for message in "$expected" 'GlobalProtect lifecycle compatibility unverified' \
    'GLOBALPROTECT_COMPATIBILITY.md#machine-checkable-release-evidence' 'source/development-only'; do
    if ! grep -Fq -- "$message" "$OUTPUT"; then
      echo "Release rejection did not explain: $message" >&2
      cat "$OUTPUT" >&2
      exit 1
    fi
  done
  if [[ -s "$TOOL_LOG" || -e "$FIXTURE_DIR/dist" ]]; then
    echo "Rejected evidence caused release-tool or artifact side effects." >&2
    cat "$TOOL_LOG" >&2
    exit 1
  fi
  CHECKS=$((CHECKS + 1))
}

assert_success() {
  if ! run_release --preflight; then
    cat "$OUTPUT" >&2
    exit 1
  fi
  for message in 'GlobalProtect lifecycle evidence gate passed' \
    'Credential-independent release preflight passed.' 'Full release still requires TASKSCOPE_CODE_SIGN_IDENTITY.'; do
    grep -Fq "$message" "$OUTPUT" || { cat "$OUTPUT" >&2; exit 1; }
  done
  if grep -v '^xcrun --find ' "$TOOL_LOG" | grep -q . || [[ -e "$FIXTURE_DIR/dist" ]]; then
    echo "Preflight attempted a build, credential, or artifact operation." >&2
    exit 1
  fi
  CHECKS=$((CHECKS + 1))
}

set_field() {
  local key="$1"
  local value="$2"
  awk -v key="$key" -v value="$value" 'index($0, key "=") == 1 { $0 = key "=" value } { print }' \
    "$MANIFEST" > "$TEST_DIR/changed"
  mv "$TEST_DIR/changed" "$MANIFEST"
}

reset_manifest() {
  cp "$TEST_DIR/valid.evidence" "$MANIFEST"
}

assert_failure 'No lifecycle manifests found'
assert_failure 'No lifecycle manifests found' --release
assert_failure 'No lifecycle manifests found' release
assert_failure 'No lifecycle manifests found' preflight

cat > "$MANIFEST" <<EOF
schema_version=1
evidence_kind=authorized-lifecycle
test_date=2026-09-26
taskscope_version=1.2.3
taskscope_build=7
source_revision=$TESTED_REVISION
bundle_id=com.example.TaskScopeTests
signing_kind=ad-hoc
install_method=staged-bundle
macos_version=26.6.2
macos_build=25G83
architecture=arm64
globalprotect_version=6.3.3-1121
agent_layout=pangpa-and-pangps
persistence_event=logout-login
coverage_gaps=none
manual_results=$EVIDENCE_RELATIVE/manual.md
EOF
printf 'Synthetic manual results; never product evidence.\n' > "$EVIDENCE_DIR/manual.md"
for step in baseline keep_off relaunch persistence keep_off_disabled open protected_service vpn managed_policy; do
  printf 'result_%s=pass\n' "$step" >> "$MANIFEST"
done
for step in baseline keep_off relaunch persistence keep_off_disabled open; do
  printf 'report_%s=%s/%s.txt\n' "$step" "$EVIDENCE_RELATIVE" "$step" >> "$MANIFEST"
  printf 'Synthetic %s snapshot; never product evidence.\n' "$step" > "$EVIDENCE_DIR/$step.txt"
done
cp "$MANIFEST" "$TEST_DIR/valid.evidence"
git -C "$FIXTURE_DIR" add Evidence
assert_success

printf '\n' >> "$MANIFEST"
assert_success
reset_manifest
printf '# A column-zero comment is allowed.\n' >> "$MANIFEST"
assert_success
reset_manifest
printf ' \t \n\t\n' >> "$MANIFEST"
assert_success
reset_manifest
awk '{ printf "%s\r\n", $0 }' "$TEST_DIR/valid.evidence" > "$MANIFEST"
assert_failure 'CRLF line endings are not supported; save with LF line endings.'
reset_manifest
printf '# A comment with CRLF\r\n' >> "$MANIFEST"
assert_failure 'CRLF line endings are not supported; save with LF line endings.'
reset_manifest
printf '\r\n' >> "$MANIFEST"
assert_failure 'CRLF line endings are not supported; save with LF line endings.'
reset_manifest
{ printf '\357\273\277'; cat "$TEST_DIR/valid.evidence"; } > "$MANIFEST"
assert_failure 'UTF-8 BOM is not supported; save UTF-8 without a BOM.'
reset_manifest
printf '  # An indented comment is not a blank line.\n' >> "$MANIFEST"
assert_failure 'unknown field or malformed'
reset_manifest

set_field agent_layout pangpa-only
set_field persistence_event reboot
set_field signing_kind apple-development
set_field install_method local-install
assert_success
set_field signing_kind developer-id
set_field install_method downloaded-archive
assert_success
reset_manifest

# Every required field is required independently; every lifecycle result must
# be pass. Historical snapshots and fixture-only records are never sufficient.
while IFS='=' read -r key value; do
  awk -v key="$key" 'index($0, key "=") != 1' "$TEST_DIR/valid.evidence" > "$MANIFEST"
  assert_failure "Missing required field: $key"
done < "$TEST_DIR/valid.evidence"
reset_manifest
for step in baseline keep_off relaunch persistence keep_off_disabled open protected_service vpn managed_policy; do
  for result in fail not-tested unknown; do
    set_field "result_$step" "$result"
    assert_failure "result_$step must be pass"
  done
  reset_manifest
done

while IFS='=' read -r key value; do
  set_field "$key" "$value"
  assert_failure "$key must "
  reset_manifest
done <<'EOF'
schema_version=2
evidence_kind=fixture
evidence_kind=live-read-only
test_date=unknown
taskscope_version=1.2.4
taskscope_build=8
source_revision=abc123
bundle_id=com.example.Other
signing_kind=unknown
install_method=unknown
macos_version=unknown
macos_build=unknown
architecture=x86_64
globalprotect_version=unknown
agent_layout=unknown
persistence_event=not-tested
coverage_gaps=policy-interference
coverage_gaps=unverified-protected-service
EOF

printf 'result_open=pass\n' >> "$MANIFEST"
assert_failure 'Duplicate field: result_open'
reset_manifest
printf 'unexpected=value\n' >> "$MANIFEST"
assert_failure 'unknown field or malformed'
reset_manifest
printf 'malformed record\n' >> "$MANIFEST"
assert_failure 'unknown field or malformed'
reset_manifest
set_field result_open ''
assert_failure 'result_open must be a nonempty value'
reset_manifest
set_field result_open 'pass '
assert_failure 'result_open must be a nonempty value without whitespace'
reset_manifest

set_field source_revision 0000000000000000000000000000000000000000
assert_failure 'must be an existing ancestor of HEAD'
reset_manifest
printf 'untested change\n' >> "$FIXTURE_DIR/Sources/candidate.txt"
assert_failure 'Candidate content differs from tested source_revision'
git -C "$FIXTURE_DIR" add Sources
assert_failure 'Candidate content differs from tested source_revision'
git -C "$FIXTURE_DIR" restore --source=HEAD --staged --worktree Sources

set_field report_open "$EVIDENCE_RELATIVE/baseline.txt"
assert_failure 'Each lifecycle snapshot needs a distinct report path'
reset_manifest
set_field report_open '/tmp/outside.txt'
assert_failure 'must be retained under'
reset_manifest
set_field report_open "$EVIDENCE_RELATIVE/../outside.txt"
assert_failure 'Invalid evidence path'
reset_manifest
set_field report_open "$EVIDENCE_RELATIVE/missing.txt"
assert_failure 'Missing, unreadable, or empty evidence file'
reset_manifest
: > "$EVIDENCE_DIR/open.txt"
assert_failure 'Missing, unreadable, or empty evidence file'
git -C "$FIXTURE_DIR" restore --worktree "$EVIDENCE_RELATIVE/open.txt"
mv "$EVIDENCE_DIR/open.txt" "$TEST_DIR/snapshot.txt"
ln -s "$TEST_DIR/snapshot.txt" "$EVIDENCE_DIR/open.txt"
assert_failure 'Evidence must not use symlinks'
rm "$EVIDENCE_DIR/open.txt"
mv "$TEST_DIR/snapshot.txt" "$EVIDENCE_DIR/open.txt"
ln -s "$EVIDENCE_DIR" "$EVIDENCE_DIR/link"
set_field report_open "$EVIDENCE_RELATIVE/link/open.txt"
assert_failure 'Evidence must not use symlinks'
rm "$EVIDENCE_DIR/link"
reset_manifest
git -C "$FIXTURE_DIR" rm -q --cached "$EVIDENCE_RELATIVE/open.txt"
assert_failure 'Evidence file is not tracked'
git -C "$FIXTURE_DIR" add Evidence
git -C "$FIXTURE_DIR" rm -q --cached "$EVIDENCE_RELATIVE/arm64.evidence"
assert_failure 'Evidence file is not tracked'
git -C "$FIXTURE_DIR" add Evidence

# A valid environment must not hide another environment with coverage gaps.
cp "$MANIFEST" "$EVIDENCE_DIR/other.evidence"
printf 'result_open=fail\n' >> "$EVIDENCE_DIR/other.evidence"
git -C "$FIXTURE_DIR" add Evidence
assert_failure 'result_open must be pass'
cp "$MANIFEST" "$EVIDENCE_DIR/other.evidence"
git -C "$FIXTURE_DIR" add Evidence
assert_success

# Retaining evidence in a subsequent commit does not invalidate the tested
# source revision. A later code commit does, even with the same version/build.
git -C "$FIXTURE_DIR" commit -qm 'Retain synthetic evidence only'
assert_success
printf 'untested committed change\n' >> "$FIXTURE_DIR/Sources/candidate.txt"
git -C "$FIXTURE_DIR" add Sources
git -C "$FIXTURE_DIR" commit -qm 'Change candidate without retesting'
assert_failure 'Candidate content differs from tested source_revision'
assert_failure 'Candidate content differs from tested source_revision' --release

echo "Release compatibility evidence tests passed ($CHECKS cases)."
