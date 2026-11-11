#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  ""|--packaging-only|--evidence-only|--pipeline-only) ;;
  *) echo "usage: $0 [--packaging-only|--evidence-only|--pipeline-only]" >&2; exit 2 ;;
esac

while IFS= read -r git_variable; do unset "$git_variable"; done < <(git rev-parse --local-env-vars)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/taskscope-release-evidence.XXXXXX")"
# bash 3.2 runs an EXIT trap with status 0 after a `set -u` abort, so only a
# run that reached a deliberate finish may pass.
TESTS_FINISHED=0
finish_tests() {
  local status="$?"
  rm -rf "$TEST_DIR"
  if [[ "$status" -eq 0 && "${TESTS_FINISHED:-0}" -ne 1 ]]; then
    echo "Release compatibility tests stopped before they finished." >&2
    status=1
  fi
  exit "$status"
}
trap finish_tests EXIT
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
# Bundles whose Info.plist and App Intents metadata match a checkout, as
# staging writes them, for the harnesses below. Nothing in them is executable.
BUNDLE_FIXTURES="$TEST_DIR/bundle-fixtures.sh"
cat > "$BUNDLE_FIXTURES" <<'EOF'
# Prints extract.actionsdata JSON that declares exactly the expectations file.
taskscope_fixture_actions_data() {
  local expected="$1"
  local group
  local count
  local index
  local name
  local phrase_count
  local phrase_index

  printf '{'
  for group in actions entities queries; do
    printf '"%s":{' "$group"
    count="$(/usr/bin/plutil -extract "$group" raw -o - "$expected")" || return 1
    for ((index = 0; index < count; index++)); do
      name="$(/usr/bin/plutil -extract "$group.$index" raw -o - "$expected")" || return 1
      [[ "$index" -eq 0 ]] || printf ','
      printf '"%s":{"identifier":"%s"}' "$name" "$name"
    done
    printf '},'
  done
  printf '"autoShortcuts":['
  count="$(/usr/bin/plutil -extract shortcuts raw -o - "$expected")" || return 1
  for ((index = 0; index < count; index++)); do
    name="$(/usr/bin/plutil -extract "shortcuts.$index.action" raw -o - "$expected")" || return 1
    [[ "$index" -eq 0 ]] || printf ','
    printf '{"actionIdentifier":"%s","phraseTemplates":[' "$name"
    phrase_count="$(/usr/bin/plutil -extract "shortcuts.$index.phrases" raw -o - "$expected")" || return 1
    for ((phrase_index = 0; phrase_index < phrase_count; phrase_index++)); do
      [[ "$phrase_index" -eq 0 ]] || printf ','
      printf '{"alternatives":[],"key":"%s"}' \
        "$(/usr/bin/plutil -extract "shortcuts.$index.phrases.$phrase_index" raw -o - "$expected")"
    done
    printf ']}'
  done
  printf ']}\n'
}

# Writes an Info.plist and App Intents metadata that pass the full check for
# ROOT, whose LICENSE and script/expected_intents.json they follow:
#   taskscope_write_bundle_fixture BUNDLE ROOT BUNDLE_ID VERSION BUILD MINIMUM
taskscope_write_bundle_fixture() {
  local bundle="$1"
  local root="$2"
  local metadata="$1/Contents/Resources/Metadata.appintents"
  local copyright

  copyright="$(/usr/bin/awk '/^Copyright \(c\) [0-9][0-9][0-9][0-9] / { print; exit }' "$root/LICENSE")"
  [[ -n "$copyright" ]] && mkdir -p "$metadata" || return 1
  cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>TaskScope</string>
  <key>CFBundleIdentifier</key><string>$3</string>
  <key>CFBundleName</key><string>TaskScope</string>
  <key>CFBundleDisplayName</key><string>TaskScope</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$4</string>
  <key>CFBundleVersion</key><string>$5</string>
  <key>LSMinimumSystemVersion</key><string>$6</string>
  <key>LSUIElement</key><false/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>$copyright</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>$3</string>
      <key>CFBundleURLSchemes</key><array><string>taskscope</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
  printf '{"toolsVersion":"fixture","version":"%s"}\n' \
    "$(/usr/bin/plutil -extract metadataVersion raw -o - "$root/script/expected_intents.json")" \
    > "$metadata/version.json" || return 1
  taskscope_fixture_actions_data "$root/script/expected_intents.json" > "$metadata/extract.actionsdata"
}

# Gives ROOT the files the full check reads: the checkout's App Intents list
# and a LICENSE copyright line.
taskscope_prepare_metadata_root() {
  mkdir -p "$1/script" || return 1
  cp "$REAL_EXPECTED_INTENTS" "$1/script/expected_intents.json" || return 1
  printf 'Copyright (c) 2026 Packaging Tests\n' > "$1/LICENSE"
}
EOF
export BUNDLE_FIXTURES
export REAL_EXPECTED_INTENTS="$ROOT_DIR/script/expected_intents.json"
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
    TASKSCOPE_OUTPUT_DIR TASKSCOPE_DSYM_COPY TASKSCOPE_FIRST_RELEASE
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
  # Without release tags any build number would pass, so only an explicit
  # first-release acknowledgement accepts an empty history.
  if taskscope_validate_build_number_history "$TEST_DIR" 1 > "$OUTPUT" 2>&1; then
    echo 'Release accepted a build number without any release tags.' >&2
    exit 1
  fi
  grep -Fq 'No local release tags' "$OUTPUT"
  TASKSCOPE_FIRST_RELEASE=1 taskscope_validate_build_number_history "$TEST_DIR" 1
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
  # Tags that merely start with v are not releases: they neither set the
  # minimum nor count as release history.
  fixture_tags=$'vendor-drop\nv-other-project'
  if taskscope_validate_build_number_history "$TEST_DIR" 1 > "$OUTPUT" 2>&1; then
    echo 'Non-release v* tags counted as release history.' >&2
    exit 1
  fi
  grep -Fq 'No local release tags' "$OUTPUT"
  fixture_tags=$'vendor-drop\nv1.0.1'
  if taskscope_validate_build_number_history "$TEST_DIR" 12 > "$OUTPUT" 2>&1; then
    exit 1
  fi
  grep -Fq 'value at v1.0.1 (12)' "$OUTPUT"
  taskscope_validate_build_number_history "$TEST_DIR" 13
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
      launch_script="$(awk '/^INSTALL_STATE="complete"/ { complete = 1 } complete && /^if \[\[ "\$OPEN_AFTER_INSTALL"/ { copying = 1 } copying { print }' "$ROOT_DIR/script/install.sh")"
    fi
    [[ -n "$launch_script" ]] || exit 1
    for mode in run --logs logs --telemetry telemetry --debug debug; do
      : > "$TOOL_LOG"
      status=0
      ROOT_DIR="$ROOT_DIR" TARGET_BUNDLE="$bundle" MODE="$mode" \
        RUNNING_PATH="$other_bundle" RUNNING_ID=com.example.TaskScopeTests \
        LAUNCH_SCRIPT="$launch_script" TOOL_LOG="$TOOL_LOG" \
        bash "$harness" > "$OUTPUT" 2>&1 || status="$?"
      if [[ "$kind" == build && "$status" -eq 0 ]] || [[ "$kind" == install && "$status" -ne 0 ]]; then
        cat "$OUTPUT" >&2; exit 1
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
    status=0
    ROOT_DIR="$ROOT_DIR" TARGET_BUNDLE="$bundle" MODE=run \
      RUNNING_PATH="$bundle" RUNNING_ID=com.example.TaskScopeTests STALE_EXECUTABLE=1 \
      LAUNCH_SCRIPT="$launch_script" TOOL_LOG="$TOOL_LOG" \
      bash "$harness" > "$OUTPUT" 2>&1 || status="$?"
    [[ "$kind" == install || "$status" -ne 0 ]] || exit 1
    [[ ! -s "$TOOL_LOG" ]] || { cat "$TOOL_LOG" >&2; exit 1; }
    grep -Fq 'older build' "$OUTPUT"
    : > "$TOOL_LOG"
    status=0
    ROOT_DIR="$ROOT_DIR" TARGET_BUNDLE="$bundle" MODE=run \
      RUNNING_PATH="$other_bundle" RUNNING_ID=com.example.TaskScopeTests INVENTORY_FAILED=1 \
      LAUNCH_SCRIPT="$launch_script" TOOL_LOG="$TOOL_LOG" \
      bash "$harness" > "$OUTPUT" 2>&1 || status="$?"
    [[ "$kind" == install || "$status" -ne 0 ]] || exit 1
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
source "$COMMON_SCRIPT"
taskscope_require_xcode() { :; }
taskscope_minimum_system_version() { printf 14.0; }
taskscope_copyright_notice() { printf 'Copyright (c) 2026 Packaging Tests'; }
DIST_DIR="$ROOT_DIR/dist/build.noindex"
APP_NAME=TaskScope
APP_BUNDLE="$DIST_DIR/TaskScope.app"
taskscope_process_identity() { printf "fake-owner-identity"; }
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
    if ! COMMON_SCRIPT="$ROOT_DIR/script/packaging_common.sh" ROOT_DIR="$fixture" MODE="$mode" VERIFY_FLOW="$flow" TOOL_LOG="$TOOL_LOG" \
      bash "$harness" > "$OUTPUT" 2>&1; then
      cat "$OUTPUT" >&2
      exit 1
    fi
    [[ "$(cat "$TOOL_LOG")" == $'static\nstartup' ]] || exit 1
    [[ ! -e "$fixture/dist/build.noindex/.TaskScope.package.lock" ]] || exit 1
    printf 'other-owner\n' > "$fixture/dist/build.noindex/.TaskScope.package.lock"
    : > "$TOOL_LOG"
    if COMMON_SCRIPT="$ROOT_DIR/script/packaging_common.sh" ROOT_DIR="$fixture" MODE="$mode" VERIFY_FLOW="$flow" TOOL_LOG="$TOOL_LOG" \
      bash "$harness" > "$OUTPUT" 2>&1; then
      echo 'Verification ignored an existing packaging lock.' >&2
      exit 1
    fi
    [[ ! -s "$TOOL_LOG" ]] || exit 1
    grep -Fq 'Another TaskScope packaging process owns' "$OUTPUT"
    grep -Fxq 'other-owner' "$fixture/dist/build.noindex/.TaskScope.package.lock"
    rm "$fixture/dist/build.noindex/.TaskScope.package.lock"
    if COMMON_SCRIPT="$ROOT_DIR/script/packaging_common.sh" ROOT_DIR="$fixture" MODE="$mode" VERIFY_FLOW="$flow" TOOL_LOG="$TOOL_LOG" FAIL_STARTUP=1 \
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
  source "$BUNDLE_FIXTURES"
  taskscope_prepare_metadata_root "$fixture"
  cat > "$harness" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$COMMON_SCRIPT"
source "$BUNDLE_FIXTURES"
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
mkdir -p "$DEST_DIR"
rm -rf "$STAGED_BUNDLE"
taskscope_write_bundle_fixture "$STAGED_BUNDLE" "$ROOT_DIR" "$BUNDLE_ID" 1.2.3 7 14.0
if [[ -n "${STAGED_DEFECT:-}" ]]; then
  /usr/bin/plutil -remove "$STAGED_DEFECT" "$STAGED_BUNDLE/Contents/Resources/Metadata.appintents/extract.actionsdata"
fi
taskscope_minimum_system_version() { printf 14.0; }
taskscope_process_identity() { printf "fake-owner-identity"; }
function /usr/bin/shlock() {
  [[ ! -e "$2" ]] || return 1
  printf '%s\n' "$4" > "$2"
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
    /usr/libexec/PlistBuddy -c "Set :$CORRUPT_KEY substituted" "$2/Contents/Info.plist"
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
    for key in CFBundleExecutable CFBundleIdentifier CFBundleShortVersionString CFBundleVersion; do
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
      [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
        "$fixture/Applications/TaskScope.app/Contents/Info.plist")" == 7 ]] || exit 1
      [[ ! -e "$fixture/dist/build.noindex/.TaskScope.package.lock" ]] || exit 1
      [[ ! -e "$fixture/Applications/.TaskScope.install.lock" ]] || exit 1
    done
    # A staged bundle whose App Intents differ from the checkout's list is
    # refused before anything is copied or stopped.
    : > "$TOOL_LOG"
    if ROOT_DIR="$fixture" COMMON_SCRIPT="$common" \
      INSTALL_DEFINITIONS="$definitions" INSTALL_FLOW="$flow" TOOL_LOG="$TOOL_LOG" \
      TASKSCOPE_SKIP_BUILD="$skip_build" STAGED_DEFECT="actions.$(/usr/bin/plutil -extract actions.0 raw -o - \
        "$fixture/script/expected_intents.json")" bash "$harness" > "$OUTPUT" 2>&1; then
      echo 'Installer accepted a staged bundle that lacks a listed App Intent.' >&2
      exit 1
    fi
    grep -Fq 'App Intents metadata lacks actions.' "$OUTPUT" && grep -Fq 'Refusing to install' "$OUTPUT" \
      || { cat "$OUTPUT" >&2; exit 1; }
    if grep -Eq 'stop-destination|verify .*installing' "$TOOL_LOG"; then
      echo 'Installer copied or stopped before refusing the staged bundle.' >&2
      exit 1
    fi
    [[ ! -e "$fixture/dist/build.noindex/.TaskScope.package.lock" ]] || exit 1
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
# A crash: an unbound variable aborts the run before it finishes. (In a
# condition, such as the right side of ||, bash 3.2 would not abort.)
unset TASKSCOPE_UNSET_FOR_TEST
if [[ "${CRASH:-0}" -eq 1 ]]; then
  : "$TASKSCOPE_UNSET_FOR_TEST"
fi
PACKAGING_TESTS_FINISHED=1
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
  # /bin/bash 3.2 runs the trap with status 0 after the abort; it must still fail.
  status=0
  FIXTURE="$fixture" CLEANUP_DEFINITIONS="$definitions" TOOL_LOG="$TOOL_LOG" LEAK=none CRASH=1 \
    /bin/bash "$harness" > "$OUTPUT" 2>&1 || status="$?"
  if [[ "$status" -eq 0 ]] || ! grep -Fq 'Packaging tests stopped before they finished' "$OUTPUT"; then
    echo 'An aborted packaging test run reported success.' >&2
    cat "$OUTPUT" >&2
    exit 1
  fi
  [[ ! -d "$fixture/work" ]] || exit 1
)

# Packaging tests sign ad hoc and stage into their own temporary directory, so
# neither the keychain nor the checkout's dist/build.noindex affects a run.
test_packaging_test_isolation() (
  local setup
  export TASKSCOPE_CODE_SIGN_IDENTITY='Apple Development: Inherited' TASKSCOPE_OUTPUT_DIR=/inherited
  setup="$(awk '{ print } /^TEST_PREFERENCES_DIR=/ { exit }' "$ROOT_DIR/script/test_packaging.sh")"
  eval "$setup"
  # TEST_DIR is now the setup's own temporary directory.
  rm -rf "$TEST_DIR"
  [[ "${TASKSCOPE_CODE_SIGN_IDENTITY:-}" == - ]] || {
    echo 'Packaging tests sign with a keychain identity.' >&2
    exit 1
  }
  [[ "${TASKSCOPE_OUTPUT_DIR:-}" == "$TEST_DIR/build.noindex" ]] || {
    echo 'Packaging tests stage outside their temporary directory.' >&2
    exit 1
  }
)

# A caller's exported Git repository (GIT_DIR in a worktree's pre-commit hook,
# for example) must not redirect the fixtures' git commands.
test_git_environment_is_cleared() (
  local script
  for script in test_packaging test_release_compatibility; do
    (
      export GIT_DIR=/caller/.git GIT_WORK_TREE=/caller GIT_INDEX_FILE=/caller/.git/index
      eval "$(awk '/^ROOT_DIR=/ { exit } { print }' "$ROOT_DIR/script/$script.sh")"
      [[ -z "${GIT_DIR:-}${GIT_WORK_TREE:-}${GIT_INDEX_FILE:-}" ]] || {
        echo "$script.sh keeps the caller's Git repository variables." >&2
        exit 1
      }
    )
  done
)

# Only argument parsing, which precedes ROOT_DIR, is evaluated here, so no
# build, install, or release step can start.
test_script_arguments_and_help() (
  local entry
  local script
  local valid
  local prefix
  local option
  local status
  for entry in build_and_run:--stage install:--no-open release:--preflight; do
    script="${entry%%:*}"
    valid="${entry#*:}"
    prefix="$(awk '/^ROOT_DIR=/ { exit } { print }' "$ROOT_DIR/script/$script.sh")"
    for option in --help -h; do
      if ! PREFIX="$prefix" bash -c 'eval "$PREFIX"' _ "$option" > "$OUTPUT" 2>&1; then
        echo "$script.sh rejected $option." >&2
        cat "$OUTPUT" >&2
        exit 1
      fi
      grep -q '^usage:' "$OUTPUT" && grep -q '^Environment:' "$OUTPUT" || {
        echo "$script.sh $option does not describe its modes and environment." >&2
        exit 1
      }
    done
    # A second option is a usage error, like a misspelled first one.
    for option in "$valid --verify" "$valid extra" --definitely-invalid; do
      status=0
      # shellcheck disable=SC2086 # Each case is a list of arguments.
      PREFIX="$prefix" bash -c 'eval "$PREFIX"' _ $option > "$OUTPUT" 2>&1 || status="$?"
      if [[ "$status" -ne 2 ]] || ! grep -q '^usage:' "$OUTPUT"; then
        echo "$script.sh did not reject arguments: $option" >&2
        exit 1
      fi
    done
  done
  # A full release must be requested explicitly.
  prefix="$(awk '/^ROOT_DIR=/ { exit } { print }' "$ROOT_DIR/script/release.sh")"
  status=0
  PREFIX="$prefix" bash -c 'eval "$PREFIX"' _ > "$OUTPUT" 2>&1 || status="$?"
  [[ "$status" -eq 2 ]] || {
    echo 'release.sh starts a full release without an explicit mode.' >&2
    exit 1
  }
)

# An invalid TASKSCOPE_VERIFIED_BUNDLE_COPY is rejected before any tool runs or
# the staged bundle changes. Every tool reached after validation is a fake.
test_verified_copy_validated_before_build() (
  local fixture="$TEST_DIR/verified copy fixture"
  local tool
  local entry
  local value
  local expected
  mkdir -p "$fixture/script" "$fixture/bin" "$fixture/Existing/TaskScope.app" \
    "$fixture/Dangling" "$fixture/Valid"
  ln -s "$fixture/missing.app" "$fixture/Dangling/TaskScope.app"
  cp "$ROOT_DIR/script/build_and_run.sh" "$ROOT_DIR/script/packaging_common.sh" "$fixture/script/"
  printf '1.2.3\n' > "$fixture/VERSION"
  printf '7\n' > "$fixture/BUILD_NUMBER"
  for tool in xcodebuild swift xcrun; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${0##*/}" >> "$TOOL_LOG"\nexit 91\n' > "$fixture/bin/$tool"
    chmod +x "$fixture/bin/$tool"
  done
  for entry in \
    "relative/TaskScope.app|must be an absolute TaskScope.app path" \
    "$fixture/Valid/Other.app|must be an absolute TaskScope.app path" \
    "$fixture/Existing/TaskScope.app|Refusing to overwrite verified bundle copy" \
    "$fixture/Dangling/TaskScope.app|Refusing to overwrite verified bundle copy" \
    "$fixture/Absent/TaskScope.app|destination directory does not exist"; do
    value="${entry%%|*}"
    expected="${entry#*|}"
    : > "$TOOL_LOG"
    if TOOL_LOG="$TOOL_LOG" PATH="$fixture/bin:$PATH" TASKSCOPE_BUNDLE_ID=com.example.TaskScopeTests \
      TASKSCOPE_CODE_SIGN_IDENTITY=- TASKSCOPE_OUTPUT_DIR="$fixture/out" \
      TASKSCOPE_VERIFIED_BUNDLE_COPY="$value" \
      bash "$fixture/script/build_and_run.sh" --stage > "$OUTPUT" 2>&1; then
      echo "Staging accepted verified copy destination $value." >&2
      exit 1
    fi
    grep -Fq "$expected" "$OUTPUT" || { cat "$OUTPUT" >&2; exit 1; }
    if [[ -s "$TOOL_LOG" || -e "$fixture/out" ]]; then
      echo "Invalid verified copy destination $value was reported only after packaging work." >&2
      exit 1
    fi
  done
  # A valid destination passes validation and reaches the Xcode check.
  : > "$TOOL_LOG"
  if TOOL_LOG="$TOOL_LOG" PATH="$fixture/bin:$PATH" TASKSCOPE_BUNDLE_ID=com.example.TaskScopeTests \
    TASKSCOPE_CODE_SIGN_IDENTITY=- TASKSCOPE_OUTPUT_DIR="$fixture/out" \
    TASKSCOPE_VERIFIED_BUNDLE_COPY="$fixture/Valid/TaskScope.app" \
    bash "$fixture/script/build_and_run.sh" --stage > "$OUTPUT" 2>&1; then
    exit 1
  fi
  grep -Fxq xcodebuild "$TOOL_LOG" || { cat "$OUTPUT" >&2; exit 1; }
)

# The installer refuses anything at the destination that is not a TaskScope
# bundle directory with the expected identifier, and refuses a launch conflict,
# before staging, stopping, or replacing anything. Every tool is a fake.
test_installer_guards_before_changes() (
  local definitions
  local flow
  local cleanup_definition
  local status
  local fixture="$TEST_DIR/installer guard fixture"
  local harness="$TEST_DIR/installer-guard-harness.sh"
  definitions="$(awk '/^cleanup_install\(\)/ { copying = 1 } /^if \[\[ ! -d "\$DEST_DIR"/ { exit } copying { print }' "$ROOT_DIR/script/install.sh")"
  flow="$(awk '/^if \[\[ ! -d "\$DEST_DIR"/ { copying = 1 } copying { print }' "$ROOT_DIR/script/install.sh")"
  cleanup_definition="$(awk '/^cleanup_install\(\)/ { copying = 1 } copying { print } copying && /^}$/ { exit }' "$ROOT_DIR/script/install.sh")"
  mkdir -p "$fixture/script"
  printf '#!/usr/bin/env bash\nprintf "stage\\n" >> "$TOOL_LOG"\n' > "$fixture/script/build_and_run.sh"
  chmod +x "$fixture/script/build_and_run.sh"
  printf '1.2.3\n' > "$fixture/VERSION"
  printf '7\n' > "$fixture/BUILD_NUMBER"
  source "$BUNDLE_FIXTURES"
  taskscope_prepare_metadata_root "$fixture"
  cat > "$harness" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$COMMON_SCRIPT"
source "$BUNDLE_FIXTURES"
APP_NAME=TaskScope
BUNDLE_ID=com.example.TaskScopeTests
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
DESTINATION_STOPPED=0
mkdir -p "$DEST_DIR"
rm -rf "$STAGED_BUNDLE"
taskscope_write_bundle_fixture "$STAGED_BUNDLE" "$ROOT_DIR" "$BUNDLE_ID" 1.2.3 7 14.0
taskscope_minimum_system_version() { printf 14.0; }
function /usr/bin/codesign() { :; }
function /usr/bin/ditto() { cp -R "$1" "$2"; }
function /usr/bin/open() { printf 'open %s\n' "$*" >> "$TOOL_LOG"; }
taskscope_running_bundle_paths() {
  [[ -z "${RUNNING_PATH:-}" ]] || printf '4242\t%s\n' "$RUNNING_PATH"
}
eval "$INSTALL_DEFINITIONS"
stop_destination_app() { printf 'stop-destination\n' >> "$TOOL_LOG"; }
eval "$INSTALL_FLOW"
EOF
  local common="$ROOT_DIR/script/packaging_common.sh"
  run_installer() {
    : > "$TOOL_LOG"
    COMMON_SCRIPT="$common" ROOT_DIR="$fixture" \
      INSTALL_DEFINITIONS="$definitions" INSTALL_FLOW="$flow" TOOL_LOG="$TOOL_LOG" \
      TASKSCOPE_SKIP_BUILD=0 bash "$harness" > "$OUTPUT" 2>&1
  }
  mkdir -p "$fixture/Applications"
  # A regular file or a dangling link named TaskScope.app is never replaced.
  printf 'precious user data\n' > "$fixture/Applications/TaskScope.app"
  if OPEN_AFTER_INSTALL=0 run_installer; then
    echo 'Installer replaced a regular file named TaskScope.app.' >&2
    exit 1
  fi
  grep -Fq 'Refusing to replace' "$OUTPUT" || { cat "$OUTPUT" >&2; exit 1; }
  grep -Fxq 'precious user data' "$fixture/Applications/TaskScope.app"
  [[ ! -s "$TOOL_LOG" ]] || { echo 'Installer staged or stopped before refusing.' >&2; exit 1; }
  rm "$fixture/Applications/TaskScope.app"
  ln -s "$fixture/missing.app" "$fixture/Applications/TaskScope.app"
  if OPEN_AFTER_INSTALL=0 run_installer; then
    echo 'Installer replaced a dangling link named TaskScope.app.' >&2
    exit 1
  fi
  grep -Fq 'Refusing to replace' "$OUTPUT"
  [[ -L "$fixture/Applications/TaskScope.app" && ! -s "$TOOL_LOG" ]] || exit 1
  rm "$fixture/Applications/TaskScope.app"
  # A same-ID app running elsewhere stops the install before any change.
  if OPEN_AFTER_INSTALL=1 RUNNING_PATH='/Elsewhere/TaskScope.app' run_installer; then
    echo 'Installer ignored a launch conflict.' >&2
    exit 1
  fi
  grep -Fq '/Elsewhere/TaskScope.app' "$OUTPUT" && grep -Fq 'Quit that copy' "$OUTPUT" \
    || { cat "$OUTPUT" >&2; exit 1; }
  if [[ -s "$TOOL_LOG" || -e "$fixture/Applications/TaskScope.app" ]]; then
    echo 'Installer changed the destination before reporting a launch conflict.' >&2
    exit 1
  fi
  # Without a conflict the install completes and opens the new bundle.
  OPEN_AFTER_INSTALL=1 run_installer || { cat "$OUTPUT" >&2; exit 1; }
  grep -Fxq "open $fixture/Applications/TaskScope.app" "$TOOL_LOG"

  # A rename that never happened must not delete what is at the destination,
  # and a confirmed stop is reported when the install then fails.
  mkdir -p "$fixture/Unrelated.app"
  status=0
  (
    eval "$cleanup_definition"
    DEST_BUNDLE="$fixture/Unrelated.app"
    INSTALLING_BUNDLE="$fixture/none"
    BACKUP_BUNDLE="$fixture/none"
    INSTALL_LOCK_ACQUIRED=0
    PACKAGING_LOCK_ACQUIRED=0
    INSTALL_STATE=installing
    DESTINATION_STOPPED=1
    false || cleanup_install
  ) > "$OUTPUT" 2>&1 || status="$?"
  [[ "$status" -eq 1 && -d "$fixture/Unrelated.app" ]] || {
    echo 'Install cleanup deleted a destination this run never created.' >&2
    exit 1
  }
  grep -Fq 'was quit for the upgrade and has not been restarted' "$OUTPUT" || {
    echo 'A failed install did not say that the stopped app stays quit.' >&2
    exit 1
  }
)

# Locks record their owner's start time and command, so a PID that was reused
# by an unrelated process no longer blocks packaging. shlock is a fake here.
test_lock_owner_identity() (
  local lock="$TEST_DIR/identity.lock"
  local owner_identity='Tue Nov 10 10:00:00 2026 bash script/build_and_run.sh --stage'
  source "$ROOT_DIR/script/packaging_common.sh"
  function /usr/bin/shlock() {
    [[ ! -e "$2" ]] || return 1
    printf '%s\n' "$4" > "$2"
  }
  taskscope_process_identity() { printf '%s' "$owner_identity"; }
  taskscope_acquire_lock "$lock" 'packaging process'
  [[ "$(head -n 1 "$lock.owner")" == "$$" ]] && grep -Fq "$owner_identity" "$lock.owner"
  # The recorded owner is still running: refuse, naming it and the remedy.
  if taskscope_acquire_lock "$lock" 'packaging process' > "$OUTPUT" 2>&1; then
    echo 'A live lock owner was ignored.' >&2
    exit 1
  fi
  grep -Fq "Recorded PID: $$" "$OUTPUT" && grep -Fq "remove $lock" "$OUTPUT"
  # The PID now belongs to an unrelated process: the lock is stale.
  owner_identity='Tue Nov 10 11:00:00 2026 /usr/libexec/unrelated'
  taskscope_acquire_lock "$lock" 'packaging process' > "$OUTPUT" 2>&1 || {
    cat "$OUTPUT" >&2
    echo 'A lock whose PID was reused still blocked packaging.' >&2
    exit 1
  }
  taskscope_release_lock "$lock"
  [[ ! -e "$lock" && ! -e "$lock.owner" ]]
  # A lock without an owner record is never broken automatically.
  printf '%s\n' "$$" > "$lock"
  if taskscope_acquire_lock "$lock" 'packaging process' > "$OUTPUT" 2>&1; then
    exit 1
  fi
  grep -Fq "remove $lock and $lock.owner" "$OUTPUT"
  rm -f "$lock"
)

# A killed run leaves hidden transaction bundles. The next run restores a
# backup when the destination is missing and removes the leftovers.
test_interrupted_transaction_recovery() (
  local recovery="$TEST_DIR/recovery"
  local fixture="$TEST_DIR/recovery fixture"
  local tool
  source "$ROOT_DIR/script/packaging_common.sh"
  function /usr/bin/codesign() { [[ ! -e "${@: -1}/invalid" ]]; }
  mkdir -p "$recovery/.TaskScope.backup.11" "$recovery/.TaskScope.installing.11"
  printf previous > "$recovery/.TaskScope.backup.11/marker"
  taskscope_recover_bundles "$recovery/TaskScope.app" "$recovery/.TaskScope.backup." \
    "$recovery/.TaskScope.installing." 2> "$OUTPUT"
  [[ "$(cat "$recovery/TaskScope.app/marker")" == previous ]] || {
    echo 'An interrupted install did not restore the previous bundle.' >&2
    exit 1
  }
  [[ ! -e "$recovery/.TaskScope.installing.11" ]] || exit 1
  # With the destination present and valid, leftovers are removed.
  mkdir -p "$recovery/.TaskScope.backup.12" "$recovery/.TaskScope.installing.12"
  taskscope_recover_bundles "$recovery/TaskScope.app" "$recovery/.TaskScope.backup." \
    "$recovery/.TaskScope.installing."
  [[ ! -e "$recovery/.TaskScope.backup.12" && ! -e "$recovery/.TaskScope.installing.12" ]] || exit 1
  # A backup is kept while the destination fails verification.
  mkdir -p "$recovery/.TaskScope.backup.13"
  touch "$recovery/TaskScope.app/invalid"
  if taskscope_recover_bundles "$recovery/TaskScope.app" "$recovery/.TaskScope.backup." \
    "$recovery/.TaskScope.installing." > "$OUTPUT" 2>&1; then
    exit 1
  fi
  [[ -d "$recovery/.TaskScope.backup.13" ]] && grep -Fq 'fails signature verification' "$OUTPUT"
  rm -rf "$recovery/TaskScope.app"
  # Two backups and no destination: the user decides which one to keep.
  mkdir -p "$recovery/.TaskScope.backup.14"
  if taskscope_recover_bundles "$recovery/TaskScope.app" "$recovery/.TaskScope.backup." \
    "$recovery/.TaskScope.installing." > "$OUTPUT" 2>&1; then
    exit 1
  fi
  grep -Fq 'Multiple backups found' "$OUTPUT"
  [[ ! -e "$recovery/TaskScope.app" ]] || exit 1

  # Staging recovers its own output under the packaging lock, before any build.
  mkdir -p "$fixture/script" "$fixture/bin" "$fixture/out/.TaskScope.output-backup.21" \
    "$fixture/out/.TaskScope.staging.21"
  printf previous > "$fixture/out/.TaskScope.output-backup.21/marker"
  cp "$ROOT_DIR/script/build_and_run.sh" "$ROOT_DIR/script/packaging_common.sh" "$fixture/script/"
  printf '1.2.3\n' > "$fixture/VERSION"
  printf '7\n' > "$fixture/BUILD_NUMBER"
  printf '#!/usr/bin/env bash\nprintf "Xcode 26.0\\nBuild version 17A1\\n"\n' > "$fixture/bin/xcodebuild"
  printf '#!/usr/bin/env bash\nexit 91\n' > "$fixture/bin/swift"
  chmod +x "$fixture/bin/xcodebuild" "$fixture/bin/swift"
  if PATH="$fixture/bin:$PATH" TASKSCOPE_BUNDLE_ID=com.example.TaskScopeTests \
    TASKSCOPE_CODE_SIGN_IDENTITY=- TASKSCOPE_OUTPUT_DIR="$fixture/out" \
    bash "$fixture/script/build_and_run.sh" --stage > "$OUTPUT" 2>&1; then
    exit 1
  fi
  [[ "$(cat "$fixture/out/TaskScope.app/marker" 2>/dev/null)" == previous ]] || {
    cat "$OUTPUT" >&2
    echo 'An interrupted stage did not restore the previous staged bundle.' >&2
    exit 1
  }
  if find "$fixture/out" -maxdepth 1 -name '.TaskScope.*.21' -print -quit | grep -q .; then
    echo 'An interrupted stage left hidden bundles behind.' >&2
    exit 1
  fi
)

test_xcode_requirement() (
  local status
  source "$ROOT_DIR/script/packaging_common.sh"
  for version in unavailable 'Xcode 25.4' 'Xcode 9.4'; do
    if [[ "$version" == unavailable ]]; then
      xcodebuild() { echo 'xcode-select: error: tool requires Xcode' >&2; return 1; }
    else
      eval "xcodebuild() { printf '%s\nBuild version 1A1\n' '$version'; }"
    fi
    status=0
    taskscope_require_xcode > "$OUTPUT" 2>&1 || status="$?"
    [[ "$status" -eq 2 ]] && grep -Fq 'needs Xcode 26 or later selected with xcode-select' "$OUTPUT" \
      && grep -Fq "found: $version" "$OUTPUT" || {
      echo "Packaging accepted $version." >&2
      cat "$OUTPUT" >&2
      exit 1
    }
  done
  xcodebuild() { printf 'Xcode 26.1\nBuild version 17B1\n'; }
  taskscope_require_xcode
)

# Staging, installing and releasing share one Info.plist and App Intents check.
# It accepts a bundle that matches the checkout and its expected_intents.json,
# names whatever differs, and the identity level checks only the identity.
test_bundle_metadata_check() (
  local root="$TEST_DIR/metadata root"
  local bundle="$TEST_DIR/metadata bundles/TaskScope.app"
  local metadata="$TEST_DIR/metadata bundles/TaskScope.app/Contents/Resources/Metadata.appintents"
  local expected="$TEST_DIR/metadata root/script/expected_intents.json"
  local status
  source "$ROOT_DIR/script/packaging_common.sh"
  source "$BUNDLE_FIXTURES"
  taskscope_prepare_metadata_root "$root"
  # A list of its own, so these cases test the rules rather than today's intents.
  cat > "$expected" <<'JSON'
{
  "metadataVersion": "3.0",
  "actions": ["FirstIntent", "SecondIntent"],
  "entities": ["ExampleEntity"],
  "queries": ["ExampleQuery"],
  "shortcuts": [
    {"action": "FirstIntent", "phrases": ["First ${applicationName}", "Begin ${applicationName}"]},
    {"action": "SecondIntent", "phrases": ["Second ${item} in ${applicationName}"]}
  ]
}
JSON
  reset_bundle() {
    rm -rf "$bundle"
    taskscope_write_bundle_fixture "$bundle" "$root" com.example.TaskScopeTests 1.2.3 7 14.0
  }
  check() {
    taskscope_verify_bundle_metadata "$1" "$bundle" "$root" com.example.TaskScopeTests 1.2.3 7 14.0 \
      > "$OUTPUT" 2>&1
  }
  accepts() {
    check "$1" || { cat "$OUTPUT" >&2; echo "The $1 metadata check refused a matching bundle." >&2; exit 1; }
  }
  refuses() {
    if check "$1"; then
      echo "The $1 metadata check accepted a bundle with: $2" >&2
      exit 1
    fi
    grep -Fq -- "$2" "$OUTPUT" || { cat "$OUTPUT" >&2; echo "The $1 check did not report: $2" >&2; exit 1; }
  }
  plist() { /usr/libexec/PlistBuddy -c "$1" "$bundle/Contents/Info.plist"; }
  edit_metadata() { /usr/bin/plutil "$@" "$metadata/extract.actionsdata"; }

  reset_bundle
  accepts full
  accepts identity
  # The checkout's own list passes against metadata written from it.
  mkdir -p "$TEST_DIR/real metadata"
  printf '{"toolsVersion":"fixture","version":"3.0"}\n' > "$TEST_DIR/real metadata/version.json"
  taskscope_fixture_actions_data "$REAL_EXPECTED_INTENTS" > "$TEST_DIR/real metadata/extract.actionsdata"
  taskscope_verify_app_intents_metadata "$TEST_DIR/real metadata" "$REAL_EXPECTED_INTENTS" \
    || { echo 'script/expected_intents.json does not accept metadata that declares exactly it.' >&2; exit 1; }
  # Usage errors are not verification failures.
  status=0
  taskscope_verify_bundle_metadata strict "$bundle" "$root" com.example.TaskScopeTests 1.2.3 7 14.0 \
    > "$OUTPUT" 2>&1 || status="$?"
  [[ "$status" -eq 2 ]] || exit 1
  grep -Fq 'Unknown bundle metadata level: strict' "$OUTPUT"
  status=0
  taskscope_verify_bundle_metadata full "$bundle" "$root" com.example.TaskScopeTests 1.2.3 7 \
    > "$OUTPUT" 2>&1 || status="$?"
  [[ "$status" -eq 2 ]] || exit 1
  grep -Fq 'needs the minimum system version' "$OUTPUT"

  # Identity: the executable, identifier, version and build, at both levels.
  for entry in CFBundleExecutable=Other CFBundleIdentifier=com.example.Other \
    CFBundleShortVersionString=1.2.4 CFBundleVersion=8; do
    plist "Set :${entry%%=*} ${entry#*=}"
    refuses identity "${entry%%=*} is '${entry#*=}'"
    refuses full "${entry%%=*} is '${entry#*=}'"
    reset_bundle
  done
  rm "$bundle/Contents/Info.plist"
  refuses identity "missing $bundle/Contents/Info.plist"
  reset_bundle

  # Full: every other Info.plist value packaging writes ...
  for entry in CFBundleName=Other CFBundleDisplayName=Other CFBundleIconFile=Other CFBundlePackageType=FMWK \
    LSMinimumSystemVersion=13.0 NSPrincipalClass=Other CFBundleInfoDictionaryVersion=5.0 \
    CFBundleDevelopmentRegion=fr LSApplicationCategoryType=public.app-category.games \
    NSHumanReadableCopyright=Other CFBundleURLTypes:0:CFBundleURLName=com.example.Other \
    CFBundleURLTypes:0:CFBundleURLSchemes:0=other; do
    plist "Set :${entry%%=*} ${entry#*=}"
    accepts identity
    refuses full "${entry%%=*} is '${entry#*=}'"
    reset_bundle
  done
  plist 'Set :LSUIElement true'
  refuses full "LSUIElement is 'true' (expected 'false')"
  reset_bundle
  for key in NSAppleEventsUsageDescription NSServerUsageDescription; do
    plist "Add :$key string legacy"
    accepts identity
    refuses full "obsolete $key is present"
    reset_bundle
  done
  # A truncated Info.plist is reported as malformed, not as a wrong value.
  /usr/bin/sed -i '' '/<\/plist>/d' "$bundle/Contents/Info.plist"
  refuses identity 'is not a valid property list'
  reset_bundle
  mv "$root/LICENSE" "$root/LICENSE.moved"
  refuses full "LICENSE lacks a 'Copyright (c) <year> <holder>' line"
  mv "$root/LICENSE.moved" "$root/LICENSE"

  # ... and App Intents metadata that matches the list exactly.
  printf '{"toolsVersion":"fixture","version":"4.0"}\n' > "$metadata/version.json"
  accepts identity
  refuses full 'App Intents version metadata is invalid'
  printf '{"version":"3.0"}\n' > "$metadata/version.json"
  refuses full 'App Intents version metadata is invalid'
  rm "$metadata/version.json"
  refuses full 'App Intents version metadata is missing'
  reset_bundle
  rm "$metadata/extract.actionsdata"
  refuses full 'App Intents action metadata is missing'
  reset_bundle
  edit_metadata -remove actions.SecondIntent
  refuses full 'App Intents metadata lacks actions.SecondIntent.'
  reset_bundle
  edit_metadata -insert actions.ExtraIntent -json '{}'
  refuses full 'App Intents metadata declares actions.ExtraIntent, which'
  reset_bundle
  edit_metadata -insert entities.ExtraEntity -json '{}'
  refuses full 'App Intents metadata declares entities.ExtraEntity, which'
  reset_bundle
  edit_metadata -remove queries
  refuses full 'App Intents metadata lacks queries.ExampleQuery.'
  reset_bundle
  edit_metadata -remove autoShortcuts
  refuses full 'App Shortcut metadata is missing'
  reset_bundle
  edit_metadata -remove autoShortcuts.0.phraseTemplates.1
  refuses full "App Shortcut phrase 'Begin \${applicationName}' is missing"
  reset_bundle
  edit_metadata -insert autoShortcuts.1.phraseTemplates.1 -json '{"alternatives":[],"key":"Extra ${applicationName}"}'
  refuses full "App Shortcut phrase 'Extra \${applicationName}' for SecondIntent is not listed"
  reset_bundle
  # A phrase moved to another action is both missing and unlisted.
  edit_metadata -remove autoShortcuts.0.phraseTemplates.1
  edit_metadata -insert autoShortcuts.1.phraseTemplates.1 -json '{"alternatives":[],"key":"Begin ${applicationName}"}'
  refuses full "App Shortcut phrase 'Begin \${applicationName}' is missing"
  grep -Fq "App Shortcut phrase 'Begin \${applicationName}' for SecondIntent is not listed" "$OUTPUT"
  reset_bundle
  edit_metadata -remove autoShortcuts.1
  refuses full 'App Intents metadata has no App Shortcut for SecondIntent.'
  reset_bundle
  edit_metadata -insert autoShortcuts.2 -json '{"actionIdentifier":"FirstIntent","phraseTemplates":[]}'
  refuses full 'App Intents metadata declares 3 App Shortcuts'
  reset_bundle
  # A broken list fails closed.
  printf '{"metadataVersion": "3.0"' > "$expected"
  refuses full 'is missing or malformed'
  accepts identity

  # The deployment target comes from Package.swift alone, in a valid form.
  taskscope_minimum_system_version() { printf '15.1'; }
  [[ "$(taskscope_resolve_minimum_system_version "$root")" == 15.1 ]]
  for bad_version in '' 'fifteen' '15' '15.1.2.3' "15.0
16.0"; do
    taskscope_minimum_system_version() { printf '%s' "$bad_version"; }
    if taskscope_resolve_minimum_system_version "$root" > "$OUTPUT" 2>&1; then
      echo "An invalid deployment target was accepted: $bad_version" >&2
      exit 1
    fi
    grep -Fq 'Could not determine the Package.swift macOS deployment target.' "$OUTPUT"
  done
  taskscope_minimum_system_version() { return 1; }
  if taskscope_resolve_minimum_system_version "$root" > /dev/null 2>&1; then
    echo 'A failed Package.swift read produced a deployment target.' >&2
    exit 1
  fi
)

# Only /usr/lib/swift may remain as a runtime search path, no @rpath library
# may be linked, and a distributed binary carries no debug-map source paths.
test_binary_search_and_debug_paths() (
  local rpath='/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx'
  local dependency='/usr/lib/libSystem.B.dylib'
  local deleted=""
  source "$ROOT_DIR/script/packaging_common.sh"
  function /usr/bin/otool() {
    if [[ "$1" == -l ]]; then
      printf 'Load command 20\n          cmd LC_RPATH\n      cmdsize 32\n         path /usr/lib/swift (offset 12)\n'
      [[ -z "$rpath" ]] || printf 'Load command 21\n          cmd LC_RPATH\n      cmdsize 120\n         path %s (offset 12)\n' "$rpath"
    else
      printf 'TaskScope:\n\t%s (compatibility version 1.0.0, current version 1.0.0)\n' "$dependency"
    fi
  }
  function /usr/bin/install_name_tool() {
    [[ "$1" == -delete_rpath && "$2" == "$rpath" ]] || return 1
    deleted="$2"
    rpath=""
  }
  if taskscope_verify_binary_paths TaskScope > "$OUTPUT" 2>&1; then
    echo 'The toolchain search path was accepted.' >&2
    exit 1
  fi
  grep -Fq 'non-system runtime search path' "$OUTPUT"
  local original="$rpath"
  taskscope_remove_build_rpaths TaskScope
  [[ "$deleted" == "$original" ]] || { echo 'The toolchain search path was not removed.' >&2; exit 1; }
  taskscope_verify_binary_paths TaskScope
  dependency='@rpath/libswiftCompatibilitySpan.dylib'
  if taskscope_verify_binary_paths TaskScope > "$OUTPUT" 2>&1; then
    exit 1
  fi
  grep -Fq 'unresolved @rpath dependency' "$OUTPUT"
  function /usr/bin/nm() { printf '0000000000000000 - 00 0000    OSO /Users/maintainer/TaskScope/.build/TaskScopeApp.o\n'; }
  if taskscope_verify_no_debug_paths TaskScope > "$OUTPUT" 2>&1; then
    exit 1
  fi
  grep -Fq 'debug OSO source paths' "$OUTPUT"
  function /usr/bin/nm() { printf '0000000100000000 T _main\n'; }
  taskscope_verify_no_debug_paths TaskScope
)

# A packaged app that exits at launch is reported with its status and output,
# not as an identity capture failure. The "app" is a script that exits at once.
test_startup_failure_is_reported() (
  local APP_NAME=TaskScope
  local BUNDLE_ID=com.example.TaskScopeTests
  local bundle="$TEST_DIR/Crashing.app"
  source "$ROOT_DIR/script/packaging_common.sh"
  mkdir -p "$bundle/Contents/MacOS"
  printf '#!/usr/bin/env bash\necho "synthetic startup failure" >&2\nexit 23\n' \
    > "$bundle/Contents/MacOS/TaskScope"
  chmod +x "$bundle/Contents/MacOS/TaskScope"
  eval "$(awk '/^verify_startup_readiness\(\)/ { copying = 1 } /^stop_staged_app_instances\(\)/ { exit } copying { print }' "$ROOT_DIR/script/build_and_run.sh")"
  unregister_staged_app() { :; }
  taskscope_send_signal() { return 1; }
  # Waits until the child has exited, whether or not bash has reaped it yet.
  wait_for_exit() {
    local state
    for _ in {1..200}; do
      state="$(/bin/ps -p "$1" -o stat= 2>/dev/null || true)"
      [[ -n "$state" && "$state" != Z* ]] || return 0
      /bin/sleep 0.05
    done
  }
  # The child exits before its identity is captured...
  taskscope_wait_for_process_identity() { wait_for_exit "$1"; return 1; }
  if verify_startup_readiness "$bundle" > "$OUTPUT" 2>&1; then
    exit 1
  fi
  grep -Fq 'packaged app exited during startup with status 23' "$OUTPUT" \
    && grep -Fq 'synthetic startup failure' "$OUTPUT" || { cat "$OUTPUT" >&2; exit 1; }
  # ...or just after.
  taskscope_wait_for_process_identity() { wait_for_exit "$1"; printf 'captured-identity'; }
  if verify_startup_readiness "$bundle" > "$OUTPUT" 2>&1; then
    exit 1
  fi
  grep -Fq 'packaged app exited during startup with status 23' "$OUTPUT" \
    && grep -Fq 'synthetic startup failure' "$OUTPUT" || { cat "$OUTPUT" >&2; exit 1; }
)

# Launch modes refuse a same-ID app running elsewhere before they take the lock,
# build, or replace the staged bundle. Every operation here is a fake.
test_launch_conflict_checked_before_build() (
  local flow
  local mode
  local status
  local harness="$TEST_DIR/launch-guard-harness.sh"
  cat > "$harness" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$COMMON_SCRIPT"
DIST_DIR="$GUARD_DIR"
APP_BUNDLE="$DIST_DIR/TaskScope.app"
BUNDLE_ID=com.example.TaskScopeTests
PACKAGING_LOCK="$DIST_DIR/.TaskScope.package.lock"
taskscope_require_xcode() { :; }
taskscope_running_bundle_paths() { printf '4242\t/Elsewhere/TaskScope.app\n'; }
taskscope_acquire_lock() { printf 'lock\n' >> "$TOOL_LOG"; }
eval "$GUARD_FLOW"
EOF
  flow="$(awk '
    /^taskscope_require_xcode$/ { copying = 1 }
    copying { print }
    copying && /^PACKAGING_LOCK_ACQUIRED=1$/ { exit }
  ' "$ROOT_DIR/script/build_and_run.sh")"
  [[ "$flow" == *taskscope_acquire_lock* ]] || {
    echo 'The packaging preamble before the lock was not found.' >&2
    exit 1
  }
  for mode in run --logs logs --telemetry telemetry --debug debug --stage stage; do
    : > "$TOOL_LOG"
    status=0
    MODE="$mode" GUARD_FLOW="$flow" GUARD_DIR="$TEST_DIR/launch guard" TOOL_LOG="$TOOL_LOG" \
      COMMON_SCRIPT="$ROOT_DIR/script/packaging_common.sh" \
      bash "$harness" > "$OUTPUT" 2>&1 || status="$?"
    case "$mode" in
      --stage|stage)
        if [[ "$status" -ne 0 ]] || ! grep -Fxq lock "$TOOL_LOG"; then
          echo "Staging without a launch refused because of a running app." >&2
          cat "$OUTPUT" >&2
          exit 1
        fi
        ;;
      *)
        if [[ "$status" -eq 0 || -s "$TOOL_LOG" ]] || ! grep -Fq '/Elsewhere/TaskScope.app' "$OUTPUT"; then
          echo "$mode did not refuse a launch conflict before packaging." >&2
          cat "$OUTPUT" >&2
          exit 1
        fi
        ;;
    esac
  done
)

# Every signature uses the hardened runtime; only --debug adds get-task-allow.
test_signing_uses_hardened_runtime() (
  local signing_flow
  local SIGNING_STYLE
  local MODE
  local CODE_SIGN_IDENTITY=-
  local STAGING_BUNDLE="$TEST_DIR/Signing.app"
  local METADATA_WORK_DIR="$TEST_DIR/signing work"
  local signed="$TEST_DIR/signing-calls"
  mkdir -p "$METADATA_WORK_DIR"
  signing_flow="$(awk '
    /^if \[\[ "\$SIGNING_STYLE" == "distribution" \]\]; then$/ { copying = 1 }
    /^verify_bundle "\$STAGING_BUNDLE"$/ { exit }
    copying { print }
  ' "$ROOT_DIR/script/build_and_run.sh")"
  [[ -n "$signing_flow" ]] || { echo 'The signing flow was not found.' >&2; exit 1; }
  function /usr/bin/codesign() {
    printf '%s\n' "$*" >> "$signed"
    if [[ "$*" == *--entitlements* ]]; then
      cat "$METADATA_WORK_DIR/debug.entitlements" >> "$signed"
    fi
  }
  for SIGNING_STYLE in development distribution; do
    for MODE in --stage run --debug; do
      : > "$signed"
      eval "$signing_flow"
      [[ "$(grep -c -- '--sign' "$signed")" -eq 1 ]] \
        && grep -q -- '--options runtime' "$signed" || {
        echo "$SIGNING_STYLE $MODE signing lacks the hardened runtime." >&2
        exit 1
      }
      if [[ "$SIGNING_STYLE" == development && "$MODE" == --debug ]]; then
        grep -Fq '<key>com.apple.security.get-task-allow</key>' "$signed"
      elif grep -q -- '--entitlements' "$signed"; then
        echo "$SIGNING_STYLE $MODE signing added entitlements." >&2
        exit 1
      fi
    done
  done
)

# Drives release.sh --release end to end through fakes: Git, signing, build,
# notarization, Gatekeeper, and archiving are shell functions injected with
# BASH_ENV. Nothing is built, signed, or sent anywhere.
test_release_pipeline() (
  local pipeline="$TEST_DIR/pipeline"
  local fixture="$pipeline/fixture"
  local evidence='Evidence/GlobalProtect/lifecycle/1.2.3-7'
  local final_dir="$fixture/dist/releases/TaskScope-1.2.3-7-macOS-arm64"
  local step
  mkdir -p "$fixture/script" "$fixture/$evidence"
  cp "$ROOT_DIR/script/release.sh" "$ROOT_DIR/script/packaging_common.sh" "$fixture/script/"
  source "$BUNDLE_FIXTURES"
  taskscope_prepare_metadata_root "$fixture"
  printf '1.2.3\n' > "$fixture/VERSION"
  printf '7\n' > "$fixture/BUILD_NUMBER"
  printf '## [1.2.3] - 2026-11-10\n' > "$fixture/CHANGELOG.md"
  # The staging step is a stub that fabricates an inert bundle and dSYM whose
  # Info.plist and App Intents metadata match the fixture checkout.
  cat > "$fixture/script/build_and_run.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${TASKSCOPE_SIGNING_STYLE:-}" == distribution && "$1" == --stage ]]
# A release stages into its own work directory, never the development output.
[[ "$TASKSCOPE_OUTPUT_DIR" == */.TaskScope.release.*/stage.noindex ]]
[[ ! -e "$TASKSCOPE_VERIFIED_BUNDLE_COPY" && ! -e "$TASKSCOPE_DSYM_COPY" ]]
source "$BUNDLE_FIXTURES"
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$TASKSCOPE_VERIFIED_BUNDLE_COPY/Contents/MacOS" "$TASKSCOPE_DSYM_COPY"
printf 'inert fixture, never executable code\n' > "$TASKSCOPE_VERIFIED_BUNDLE_COPY/Contents/MacOS/TaskScope"
chmod +x "$TASKSCOPE_VERIFIED_BUNDLE_COPY/Contents/MacOS/TaskScope"
taskscope_write_bundle_fixture "$TASKSCOPE_VERIFIED_BUNDLE_COPY" "$root" "$TASKSCOPE_BUNDLE_ID" 1.2.3 7 14.0
if [[ "$SCENARIO" == missing-intent ]]; then
  /usr/bin/plutil -remove "actions.$(/usr/bin/plutil -extract actions.0 raw -o - "$root/script/expected_intents.json")" \
    "$TASKSCOPE_VERIFIED_BUNDLE_COPY/Contents/Resources/Metadata.appintents/extract.actionsdata"
fi
touch "$TOOL_LOG.built"
EOF
  chmod +x "$fixture/script/build_and_run.sh"
  # Evidence validation runs for real; only its Git facts come from the fake.
  cat > "$fixture/$evidence/arm64.evidence" <<EOF
schema_version=1
evidence_kind=authorized-lifecycle
test_date=$(date -u +%F)
taskscope_version=1.2.3
taskscope_build=7
source_revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
bundle_id=com.example.TaskScopeTests
signing_kind=ad-hoc
install_method=staged-bundle
macos_version=26.0
macos_build=25A1
architecture=arm64
globalprotect_version=6.3.3
agent_layout=pangpa-only
persistence_event=reboot
coverage_gaps=none
manual_results=$evidence/manual.txt
EOF
  printf 'Synthetic manual results; never product evidence.\n' > "$fixture/$evidence/manual.txt"
  for step in baseline keep_off relaunch persistence keep_off_disabled open protected_service vpn managed_policy; do
    printf 'result_%s=pass\n' "$step" >> "$fixture/$evidence/arm64.evidence"
  done
  for step in baseline keep_off relaunch persistence keep_off_disabled open; do
    printf 'report_%s=%s/%s.txt\n' "$step" "$evidence" "$step" >> "$fixture/$evidence/arm64.evidence"
    printf 'Synthetic %s snapshot; never product evidence.\n' "$step" > "$fixture/$evidence/$step.txt"
  done
  cat > "$pipeline/fakes.sh" <<'EOF'
git() (
  if [[ "${1:-}" == -C ]]; then cd "$2"; shift 2; fi
  case "$1" in
    rev-parse)
      case "$*" in
        *--local-env-vars*) command git rev-parse --local-env-vars ;;
        *refs/tags/*) [[ "$SCENARIO" == existing-tag ]] ;;
        *--abbrev-ref*) [[ "$SCENARIO" != no-upstream ]] || return 1; printf 'origin/main\n' ;;
        *)
          if [[ "$SCENARIO" == unpushed && "$2" == HEAD ]]; then printf '%040d\n' 1
          else printf '%040d\n' 2; fi ;;
      esac ;;
    tag) printf 'v1.0.0\n' ;;
    show) if [[ "$*" == *BUILD_NUMBER* ]]; then printf '2\n'; else date -u +%F; fi ;;
    ls-files|merge-base|diff) return 0 ;;
    hash-object) command shasum -a 256 "${@: -1}" | awk '{ print $1 }' ;;
    status)
      if [[ "$SCENARIO" == dirty || ( "$SCENARIO" == build-dirty && -e "$TOOL_LOG.built" ) ]]; then
        printf ' M Sources/file.swift\n'
      fi ;;
    symbolic-ref)
      if [[ "$*" == *origin/HEAD* ]]; then printf 'origin/main\n'
      elif [[ "$SCENARIO" == detached ]]; then return 1
      elif [[ "$SCENARIO" == side-branch ]]; then printf 'feature\n'
      else printf 'main\n'; fi ;;
    fetch) printf 'fetch %s\n' "$*" >> "$TOOL_LOG" ;;
    remote) printf 'https://example.invalid/TaskScope.git\n' ;;
    *) echo "Unexpected Git operation: $*" >&2; return 91 ;;
  esac
)
function /usr/bin/security() {
  [[ "$SCENARIO" != missing-identity ]] || return 0
  printf '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "%s: Tests"\n' \
    "$([[ "$SCENARIO" == wrong-identity ]] && echo 'Apple Development' || echo 'Developer ID Application')"
}
function /usr/bin/codesign() {
  case "$*" in
    *-dvvv*)
      [[ "$SCENARIO" == missing-runtime ]] || printf 'CodeDirectory v=20500 flags=0x10000(runtime)\n'
      if [[ "$SCENARIO" == wrong-team ]]; then printf 'TeamIdentifier=WRONGTEAM1\n'
      else printf 'TeamIdentifier=ABCDEFGHIJ\n'; fi ;;
    *--entitlements*)
      [[ "$SCENARIO" != entitlements ]] || printf '<plist><dict><key>unexpected</key><true/></dict></plist>\n' ;;
    *) return 0 ;;
  esac
}
codesign() { /usr/bin/codesign "$@"; }
function /usr/bin/vtool() { printf 'minos 14.0\n'; }
function /usr/bin/otool() {
  if [[ "$1" == -L ]]; then
    printf 'TaskScope:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n'
  else
    printf '          cmd LC_RPATH\n         path /usr/lib/swift (offset 12)\n'
    [[ "$SCENARIO" != rpath ]] \
      || printf '          cmd LC_RPATH\n         path /Applications/Xcode.app/toolchain (offset 12)\n'
  fi
}
function /usr/bin/nm() {
  if [[ "$SCENARIO" == debug-paths ]]; then printf '0000 - 00 0000 OSO /Users/maintainer/TaskScopeApp.o\n'
  else printf '0000 T _main\n'; fi
}
lipo() { printf 'arm64\n'; }
dwarfdump() { printf 'UUID: 01234567-89AB-CDEF-0123-456789ABCDEF (arm64) fixture\n'; }
xcodebuild() { printf 'Xcode 26.0\nBuild version 17A1\n'; }
swift() {
  if [[ "$1" == package ]]; then printf '{"platforms":[{"platformName":"macos","version":"14.0"}]}\n'
  else printf 'Swift version 6.2\n'; fi
}
function /usr/bin/shlock() {
  [[ "$SCENARIO" != locked ]] || return 1
  printf '%s\n' "$4" > "$2"
}
shlock() { /usr/bin/shlock "$@"; }
function /bin/ps() { printf 'Tue Nov 10 10:00:00 2026 bash script/release.sh --release\n'; }
function /usr/sbin/spctl() { printf 'spctl %s\n' "$*" >> "$TOOL_LOG"; }
spctl() { /usr/sbin/spctl "$@"; }
xcrun() {
  case "$*" in
    '--find '*) return 0 ;;
    'notarytool history '*) return 0 ;;
    'notarytool submit '*)
      printf 'notarytool submit\n' >> "$TOOL_LOG"
      if [[ "$SCENARIO" == rejected ]]; then printf '{"status":"Invalid","id":"fixture-id"}\n'
      else printf '{"status":"Accepted","id":"fixture-id"}\n'; fi ;;
    'notarytool log '*) printf '{"diagnostic":"synthetic"}\n' > "${@: -1}" ;;
    'stapler '*) printf 'stapler %s\n' "$1 $2" >> "$TOOL_LOG" ;;
    '--sdk macosx --show-sdk-version') printf '26.0\n' ;;
    *) echo "Unexpected xcrun: $*" >&2; return 91 ;;
  esac
}
# A tar file stands in for each ZIP archive.
function /usr/bin/ditto() {
  case "$1" in
    -c) local source="${@: -2:1}"; /usr/bin/tar -cf "${@: -1}" -C "$(dirname "$source")" "$(basename "$source")" ;;
    -x) /usr/bin/tar -xf "$3" -C "$4" ;;
    *) cp "$1" "$2" ;;
  esac
}
ditto() { /usr/bin/ditto "$@"; }
EOF
  local pipeline_output="$pipeline/output"
  local pipeline_tools="$pipeline/tools"
  run_pipeline_case() {
    local scenario="$1"
    local mode="${2:---release}"
    rm -rf "$fixture/dist"
    rm -f "$pipeline_tools.built"
    : > "$pipeline_tools"
    if [[ "$scenario" == stale-work ]]; then
      mkdir -p "$fixture/dist/.TaskScope.release.EARLIER/TaskScope.app"
    fi
    (
      export BASH_ENV="$pipeline/fakes.sh" SCENARIO="$scenario" TOOL_LOG="$pipeline_tools"
      export TASKSCOPE_BUNDLE_ID=com.example.TaskScopeTests TASKSCOPE_RELEASE_ARCHS=arm64
      export TASKSCOPE_CODE_SIGN_IDENTITY='Developer ID Application: Tests'
      export TASKSCOPE_EXPECTED_TEAM_ID=ABCDEFGHIJ TASKSCOPE_NOTARY_KEYCHAIN_PROFILE=Tests
      unset TASKSCOPE_KEEP_RELEASE_WORK TASKSCOPE_FIRST_RELEASE
      case "$scenario" in
        no-identity) unset TASKSCOPE_CODE_SIGN_IDENTITY ;;
        # Requested by SHA-1, the keychain's identity is an Apple Development one.
        wrong-identity) export TASKSCOPE_CODE_SIGN_IDENTITY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA ;;
        no-team) unset TASKSCOPE_EXPECTED_TEAM_ID ;;
        bad-team) export TASKSCOPE_EXPECTED_TEAM_ID=abc ;;
        no-profile) unset TASKSCOPE_NOTARY_KEYCHAIN_PROFILE ;;
        archs) export TASKSCOPE_RELEASE_ARCHS='arm64 x86_64' ;;
        existing-output) mkdir -p "$final_dir" ;;
        keep-rejected) export TASKSCOPE_KEEP_RELEASE_WORK=1 SCENARIO=rejected ;;
      esac
      "${PIPELINE_BASH:-bash}" "$fixture/script/release.sh" "$mode"
    ) > "$pipeline_output" 2>&1
  }
  assert_pipeline_failure() {
    local scenario="$1"
    local expected="$2"
    local mode="${3:---release}"
    if run_pipeline_case "$scenario" "$mode"; then
      echo "Release $mode accepted scenario $scenario." >&2
      cat "$pipeline_output" >&2
      exit 1
    fi
    grep -Fq -- "$expected" "$pipeline_output" || {
      cat "$pipeline_output" >&2
      echo "Release $mode did not explain scenario $scenario: $expected" >&2
      exit 1
    }
    [[ ! -e "$final_dir/SHA256SUMS" ]] || {
      echo "Rejected scenario $scenario published artifacts." >&2
      exit 1
    }
    case "$scenario" in
      rejected|keep-rejected) ;;
      *)
        if grep -q '^notarytool submit' "$pipeline_tools"; then
          echo "Rejected scenario $scenario reached notarization." >&2
          exit 1
        fi
        ;;
    esac
    CHECKS=$((CHECKS + 1))
  }
  # Offline preflight rejects bad inputs before any credential or build step.
  assert_pipeline_failure archs 'architecture policy is arm64 only' --preflight
  assert_pipeline_failure existing-tag 'Release tag v1.2.3 already exists' --preflight
  assert_pipeline_failure existing-output 'Refusing to overwrite existing release output' --preflight
  printf 'invalid\n' > "$fixture/VERSION"
  assert_pipeline_failure clean 'Invalid VERSION value' --preflight
  printf '1.2.3\n' > "$fixture/VERSION"
  printf '0\n' > "$fixture/BUILD_NUMBER"
  assert_pipeline_failure clean 'Invalid BUILD_NUMBER value' --preflight
  printf '7\n' > "$fixture/BUILD_NUMBER"
  # A version must be matched literally, so 1x2y3 is not a 1.2.3 heading.
  printf '## [1x2y3] - 2026-11-10\n' > "$fixture/CHANGELOG.md"
  assert_pipeline_failure clean "lacks a '## [1.2.3]' heading" --preflight
  printf '## [1.2.3.4] - 2026-11-10\n' > "$fixture/CHANGELOG.md"
  assert_pipeline_failure clean "lacks a '## [1.2.3]' heading" --preflight
  printf '## [Unreleased]\n\n- Pending change\n\n## [1.2.3] - 2026-11-10\n' > "$fixture/CHANGELOG.md"
  assert_pipeline_failure clean 'still has Unreleased entries' --preflight
  printf '## [Unreleased]\n\n## [1.2.3] - 2026-11-10\n' > "$fixture/CHANGELOG.md"
  # Full releases check credentials, the repository, and the signed bundle.
  assert_pipeline_failure no-identity 'TASKSCOPE_CODE_SIGN_IDENTITY is required'
  assert_pipeline_failure no-team '10-character Apple Team ID'
  assert_pipeline_failure bad-team '10-character Apple Team ID'
  assert_pipeline_failure no-profile 'TASKSCOPE_NOTARY_KEYCHAIN_PROFILE is required'
  assert_pipeline_failure missing-identity 'not available with its private key'
  assert_pipeline_failure wrong-identity 'must name a Developer ID Application identity'
  assert_pipeline_failure dirty 'clean Git worktree'
  assert_pipeline_failure detached 'detached HEAD'
  assert_pipeline_failure side-branch 'default branch main'
  assert_pipeline_failure no-upstream 'configured upstream'
  assert_pipeline_failure unpushed 'must match its fetched upstream'
  assert_pipeline_failure locked 'Another TaskScope release process owns'
  assert_pipeline_failure build-dirty 'Release build changed the Git worktree'
  assert_pipeline_failure missing-runtime 'hardened runtime is absent'
  # The release runs the same Info.plist and App Intents check as staging.
  assert_pipeline_failure missing-intent 'App Intents metadata lacks actions.'
  assert_pipeline_failure wrong-team 'signing Team ID mismatch'
  assert_pipeline_failure entitlements 'unexpectedly contains entitlements'
  assert_pipeline_failure rpath 'unsafe runtime search paths'
  assert_pipeline_failure debug-paths 'debug OSO source paths remain'
  # A rejected notarization publishes nothing and removes the signed work,
  # keeping only the notary diagnostics.
  assert_pipeline_failure rejected 'Notarization was not accepted (status: Invalid)'
  if find "$fixture/dist" -maxdepth 1 -name '.TaskScope.release.*' -type d -print -quit | grep -q .; then
    echo 'A failed release kept its signed work directory.' >&2
    exit 1
  fi
  find "$fixture/dist" -name 'TaskScope-1.2.3-7-macOS-arm64-notary-log.json' -path '*notary-diagnostics*' \
    -print -quit | grep -q . || { echo 'A failed release dropped the notary log.' >&2; exit 1; }
  assert_pipeline_failure keep-rejected 'Release work preserved for diagnosis'
  find "$fixture/dist" -maxdepth 1 -name '.TaskScope.release.*' -type d -print -quit | grep -q . \
    || { echo 'TASKSCOPE_KEEP_RELEASE_WORK=1 did not keep the work directory.' >&2; exit 1; }
  # A release that aborts right after arming its trap fails, releases its lock
  # and publishes nothing, although /bin/bash 3.2 runs the trap with status 0.
  cp "$fixture/script/release.sh" "$pipeline/release.sh.original"
  awk -v injection=': "$TASKSCOPE_UNSET_FOR_TEST"' \
    '{ print } !done && /^trap .*cleanup_release.* EXIT$/ { print injection; done = 1 }' \
    "$pipeline/release.sh.original" > "$fixture/script/release.sh"
  grep -Fxq ': "$TASKSCOPE_UNSET_FOR_TEST"' "$fixture/script/release.sh"
  if PIPELINE_BASH=/bin/bash run_pipeline_case clean; then
    echo 'A release aborted by an unbound variable reported success.' >&2
    cat "$pipeline_output" >&2
    exit 1
  fi
  grep -Fq 'unbound variable' "$pipeline_output" \
    && grep -Fq 'The release stopped before it finished' "$pipeline_output" || {
    cat "$pipeline_output" >&2
    exit 1
  }
  if [[ -e "$fixture/dist/.TaskScope.release.lock" || -e "$final_dir" ]]; then
    echo 'An aborted release kept its lock or published artifacts.' >&2
    exit 1
  fi
  cp "$pipeline/release.sh.original" "$fixture/script/release.sh"
  CHECKS=$((CHECKS + 1))
  # A complete run publishes exactly the five artifacts, named with the build
  # number, records where the commit came from, and prunes earlier work.
  if ! run_pipeline_case stale-work; then
    cat "$pipeline_output" >&2
    exit 1
  fi
  [[ "$(find "$final_dir" -type f | wc -l | tr -d ' ')" -eq 5 ]] || { ls -la "$final_dir" >&2; exit 1; }
  for step in TaskScope-1.2.3-7-macOS-arm64.zip TaskScope-1.2.3-7-macOS-arm64-dSYM.zip \
    TaskScope-1.2.3-7-macOS-arm64-provenance.txt TaskScope-1.2.3-7-macOS-arm64-notary.json SHA256SUMS; do
    [[ -s "$final_dir/$step" ]] || { echo "The release lacks $step." >&2; exit 1; }
  done
  grep -Fxq 'git_branch=main' "$final_dir/TaskScope-1.2.3-7-macOS-arm64-provenance.txt"
  grep -Fxq 'git_upstream=origin/main' "$final_dir/TaskScope-1.2.3-7-macOS-arm64-provenance.txt"
  grep -Fxq 'git_remote_url=https://example.invalid/TaskScope.git' "$final_dir/TaskScope-1.2.3-7-macOS-arm64-provenance.txt"
  grep -Fq 'fetch --tags origin' "$pipeline_tools"
  if find "$fixture/dist" -maxdepth 1 -name '.TaskScope.release.*' -type d -print -quit | grep -q .; then
    echo 'A release left earlier or current work directories behind.' >&2
    exit 1
  fi
  [[ ! -e "$fixture/dist/build.noindex" ]] || {
    echo 'A release replaced the development staged bundle.' >&2
    exit 1
  }
  CHECKS=$((CHECKS + 1))
  echo "Release pipeline tests passed ($CHECKS cases)."
)

# Under /bin/bash 3.2 an EXIT trap runs with status 0 after a `set -u` abort.
# A fault injected right after a script arms its trap must still fail the run,
# and the trap must still release what the run held. Nothing is launched.
test_unexpected_exit_fails() (
  local fixture="$TEST_DIR/unexpected exit fixture"
  local injection=': "$TASKSCOPE_UNSET_FOR_TEST"'
  local status
  local readiness_function
  local APP_NAME=TaskScope
  local BUNDLE_ID=com.example.TaskScopeTests
  unset TASKSCOPE_UNSET_FOR_TEST
  mkdir -p "$fixture/script" "$fixture/bin" "$fixture/Applications"
  cp "$ROOT_DIR/script/packaging_common.sh" "$fixture/script/"
  printf '1.2.3\n' > "$fixture/VERSION"
  printf '7\n' > "$fixture/BUILD_NUMBER"
  printf '#!/usr/bin/env bash\nprintf "Xcode 26.0\\nBuild version 17A1\\n"\n' > "$fixture/bin/xcodebuild"
  chmod +x "$fixture/bin/xcodebuild"
  # Prints the input with the fault inserted after the first line matching $1.
  inject_after() {
    awk -v pattern="$1" -v injection="$injection" \
      '{ print } !done && $0 ~ pattern { print injection; done = 1 }'
  }
  expect_failure() {
    local message="$1"
    if [[ "$status" -eq 0 ]] || ! grep -Fq 'unbound variable' "$OUTPUT" || ! grep -Fq "$message" "$OUTPUT"; then
      echo "A run aborted by an unbound variable reported success: $message" >&2
      cat "$OUTPUT" >&2
      exit 1
    fi
  }
  # Staging, once it holds the packaging lock.
  inject_after '^PACKAGING_LOCK_ACQUIRED=1$' < "$ROOT_DIR/script/build_and_run.sh" \
    > "$fixture/script/build_and_run.sh"
  grep -Fxq "$injection" "$fixture/script/build_and_run.sh"
  status=0
  PATH="$fixture/bin:$PATH" TASKSCOPE_BUNDLE_ID="$BUNDLE_ID" TASKSCOPE_CODE_SIGN_IDENTITY=- \
    TASKSCOPE_OUTPUT_DIR="$fixture/out" /bin/bash "$fixture/script/build_and_run.sh" --stage \
    > "$OUTPUT" 2>&1 || status="$?"
  expect_failure 'Packaging stopped before it finished'
  [[ ! -e "$fixture/out/.TaskScope.package.lock" ]] || {
    echo 'An aborted stage kept the packaging lock.' >&2
    exit 1
  }
  # Installing, once it holds the destination lock.
  inject_after '^INSTALL_LOCK_ACQUIRED=1$' < "$ROOT_DIR/script/install.sh" > "$fixture/script/install.sh"
  grep -Fxq "$injection" "$fixture/script/install.sh"
  status=0
  DEST_DIR="$fixture/Applications" TASKSCOPE_SKIP_BUILD=1 TASKSCOPE_BUNDLE_ID="$BUNDLE_ID" \
    TASKSCOPE_OUTPUT_DIR="$fixture/out" /bin/bash "$fixture/script/install.sh" --no-open \
    > "$OUTPUT" 2>&1 || status="$?"
  expect_failure 'The installer stopped before it finished'
  [[ ! -e "$fixture/Applications/.TaskScope.install.lock" ]] || {
    echo 'An aborted install kept the destination lock.' >&2
    exit 1
  }
  # Startup verification, before it launches anything. A separate process keeps
  # the call out of a condition, where bash 3.2 would not abort at all.
  cat > "$fixture/readiness-harness.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$COMMON_SCRIPT"
APP_NAME=TaskScope
BUNDLE_ID=com.example.TaskScopeTests
eval "$READINESS_FUNCTION"
unregister_staged_app() { :; }
taskscope_send_signal() { return 1; }
verify_startup_readiness "$NEVER_LAUNCHED_BUNDLE"
echo 'Startup verification returned success.'
EOF
  readiness_function="$(awk '/^verify_startup_readiness\(\)/ { copying = 1 } /^stop_staged_app_instances\(\)/ { exit } copying { print }' \
    "$ROOT_DIR/script/build_and_run.sh" | inject_after 'trap .*cleanup_readiness_process.* EXIT$')"
  grep -Fxq "$injection" <<< "$readiness_function"
  status=0
  COMMON_SCRIPT="$ROOT_DIR/script/packaging_common.sh" NEVER_LAUNCHED_BUNDLE="$fixture/Never Launched.app" \
    READINESS_FUNCTION="$readiness_function" \
    /bin/bash "$fixture/readiness-harness.sh" > "$OUTPUT" 2>&1 || status="$?"
  if [[ "$status" -eq 0 ]] || ! grep -Fq 'unbound variable' "$OUTPUT" \
    || grep -Fq 'Startup verification returned success.' "$OUTPUT"; then
    echo 'Startup verification reported success after it aborted.' >&2
    cat "$OUTPUT" >&2
    exit 1
  fi
  # This suite itself, right after it arms its trap.
  inject_after '^trap .* EXIT$' < "$ROOT_DIR/script/test_release_compatibility.sh" \
    > "$fixture/script/test_release_compatibility.sh"
  grep -Fxq "$injection" "$fixture/script/test_release_compatibility.sh"
  status=0
  /bin/bash "$fixture/script/test_release_compatibility.sh" --packaging-only > "$OUTPUT" 2>&1 || status="$?"
  expect_failure 'Release compatibility tests stopped before they finished'
)

TEST_MODE="${1:-}"
if [[ -z "$TEST_MODE" || "$TEST_MODE" == --packaging-only ]]; then
  test_packaging_preferences_cleanup
  test_install_locks_and_rechecks_copy
  test_verify_holds_packaging_lock
  test_launch_refuses_other_bundle_path
  test_staging_stops_before_swap
  test_packaging_environment_isolation
  test_build_number_history
  test_packaging_test_isolation
  test_git_environment_is_cleared
  test_script_arguments_and_help
  test_verified_copy_validated_before_build
  test_installer_guards_before_changes
  test_lock_owner_identity
  test_interrupted_transaction_recovery
  test_xcode_requirement
  test_binary_search_and_debug_paths
  test_bundle_metadata_check
  test_startup_failure_is_reported
  test_launch_conflict_checked_before_build
  test_signing_uses_hardened_runtime
  test_unexpected_exit_fails
  echo 'Packaging regression tests passed (21 groups).'
fi
if [[ -z "$TEST_MODE" || "$TEST_MODE" == --pipeline-only ]]; then
  test_release_pipeline
fi
if [[ -n "$TEST_MODE" && "$TEST_MODE" != --evidence-only ]]; then
  TESTS_FINISHED=1
  exit 0
fi

mkdir -p "$FIXTURE_DIR/script" "$FIXTURE_DIR/Sources" "$EVIDENCE_DIR" "$FAKE_BIN"
cp "$ROOT_DIR/script/release.sh" "$ROOT_DIR/script/packaging_common.sh" "$FIXTURE_DIR/script/"
printf '1.2.3\n' > "$FIXTURE_DIR/VERSION"
printf '7\n' > "$FIXTURE_DIR/BUILD_NUMBER"
printf '## [1.2.3] - 2026-09-26\n' > "$FIXTURE_DIR/CHANGELOG.md"
printf 'tested candidate\n' > "$FIXTURE_DIR/Sources/candidate.txt"
git init -q -b main "$FIXTURE_DIR"
[[ "$(cd "$(git -C "$FIXTURE_DIR" rev-parse --absolute-git-dir)" && pwd -P)" == "$(cd "$FIXTURE_DIR/.git" && pwd -P)" ]] || {
  echo 'Fixture Git directory escaped the temporary repository.' >&2; exit 1;
}
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
if [[ "${0##*/}" == xcodebuild && "${1:-}" == -version ]]; then
  printf 'Xcode 26.0\nBuild version 17A1\n'; exit 0
fi
if [[ "${0##*/}" == swift && "${1:-}" == package ]]; then
  printf '{"platforms":[{"platformName":"macos","version":"14.0"}]}\n'; exit 0
fi
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
    TASKSCOPE_FIRST_RELEASE=1 TASKSCOPE_BUNDLE_ID=com.example.TaskScopeTests TASKSCOPE_RELEASE_ARCHS=arm64 \
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
  if [[ -n "$(grep -Ev '^(xcrun --find |xcodebuild -version|swift package )' "$TOOL_LOG")" || -e "$FIXTURE_DIR/dist" ]]; then
    echo "Preflight attempted a build, credential, or artifact operation." >&2
    exit 1
  fi
  CHECKS=$((CHECKS + 1))
}

# Rejections of the release inputs themselves, before the evidence gate.
assert_input_failure() {
  local expected="$1"
  if run_release --preflight; then
    echo "Release preflight unexpectedly accepted: $expected" >&2
    exit 1
  fi
  grep -Fq -- "$expected" "$OUTPUT" || { cat "$OUTPUT" >&2; exit 1; }
  if [[ -s "$TOOL_LOG" || -e "$FIXTURE_DIR/dist" ]]; then
    echo "Rejected release inputs caused release-tool or artifact side effects." >&2
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
test_date=$(date -u +%F)
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

# release.sh inspects the checkout it releases even when the caller exports
# another repository, as a hook in a linked worktree does with GIT_DIR.
git init -q "$TEST_DIR/decoy repository"
GIT_DIR="$TEST_DIR/decoy repository/.git" GIT_WORK_TREE="$TEST_DIR/decoy repository" \
  GIT_INDEX_FILE="$TEST_DIR/decoy repository/.git/index" assert_success

# A version whose release tag already exists cannot be released again, even
# when its build number is higher than the tagged one.
EARLIER_BUILD_BLOB="$(printf '6\n' | git -C "$FIXTURE_DIR" hash-object -w --stdin)"
EARLIER_TREE="$(printf '100644 blob %s\tBUILD_NUMBER\n' "$EARLIER_BUILD_BLOB" | git -C "$FIXTURE_DIR" mktree)"
EARLIER_COMMIT="$(git -C "$FIXTURE_DIR" commit-tree "$EARLIER_TREE" -m 'Earlier release of 1.2.3')"
git -C "$FIXTURE_DIR" tag v1.2.3 "$EARLIER_COMMIT"
assert_input_failure 'Release tag v1.2.3 already exists'
git -C "$FIXTURE_DIR" tag -d v1.2.3 >/dev/null

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

# A manifest kept in a subdirectory would otherwise be skipped silently, even
# one that is tracked but missing from the working tree.
mkdir -p "$EVIDENCE_DIR/nested"
cp "$MANIFEST" "$EVIDENCE_DIR/nested/hidden.evidence"
assert_failure 'Place each manifest directly in'
git -C "$FIXTURE_DIR" add Evidence
rm "$EVIDENCE_DIR/nested/hidden.evidence"
assert_failure 'Place each manifest directly in'
git -C "$FIXTURE_DIR" rm -q --cached "$EVIDENCE_RELATIVE/nested/hidden.evidence"
rmdir "$EVIDENCE_DIR/nested"
# Test dates must be real calendar dates between the tested commit and today.
for bad_date in 2026-02-30 2026-13-01 0000-00-00 2099-01-01 2000-01-01; do
  set_field test_date "$bad_date"
  case "$bad_date" in
    2099-01-01) assert_failure 'must not be in the future' ;;
    2000-01-01) assert_failure 'precedes source_revision author date' ;;
    *) assert_failure 'valid calendar date' ;;
  esac
  reset_manifest
done
# Every artifact is a distinct file: manual results are not a snapshot, no
# artifact is a manifest, and no two artifacts share contents.
set_field manual_results "$EVIDENCE_RELATIVE/baseline.txt"
assert_failure 'distinct report path'
reset_manifest
set_field manual_results "$EVIDENCE_RELATIVE/arm64.evidence"
assert_failure 'cannot be a .evidence manifest'
reset_manifest
set_field report_open "$EVIDENCE_RELATIVE/arm64.evidence"
assert_failure 'cannot be a .evidence manifest'
reset_manifest
cp "$EVIDENCE_DIR/open.txt" "$TEST_DIR/open-original"
cp "$EVIDENCE_DIR/baseline.txt" "$EVIDENCE_DIR/open.txt"
assert_failure 'must have distinct contents'
rm "$EVIDENCE_DIR/open.txt"
ln "$EVIDENCE_DIR/baseline.txt" "$EVIDENCE_DIR/open.txt"
assert_failure 'must have distinct contents'
rm "$EVIDENCE_DIR/open.txt"
cp "$TEST_DIR/open-original" "$EVIDENCE_DIR/open.txt"

# A valid environment must not hide another environment with coverage gaps.
cp "$MANIFEST" "$EVIDENCE_DIR/other.evidence"
printf 'result_open=fail\n' >> "$EVIDENCE_DIR/other.evidence"
git -C "$FIXTURE_DIR" add Evidence
assert_failure 'result_open must be pass'
# A copied manifest is the same environment, not a second tested one.
cp "$MANIFEST" "$EVIDENCE_DIR/other.evidence"
assert_failure 'Duplicate tested environment'
sed 's/macos_build=25G83/macos_build=25G84/' "$MANIFEST" > "$EVIDENCE_DIR/other.evidence"
git -C "$FIXTURE_DIR" add Evidence
assert_success
grep -Fq 'evidence gate passed (2 tested environment(s))' "$OUTPUT"

# Retaining evidence in a subsequent commit does not invalidate the tested
# source revision. A later code commit does, even with the same version/build.
git -C "$FIXTURE_DIR" commit -qm 'Retain synthetic evidence only'
assert_success
printf 'untested committed change\n' >> "$FIXTURE_DIR/Sources/candidate.txt"
git -C "$FIXTURE_DIR" add Sources
git -C "$FIXTURE_DIR" commit -qm 'Change candidate without retesting'
assert_failure 'Candidate content differs from tested source_revision'
assert_failure 'Candidate content differs from tested source_revision' --release

TESTS_FINISHED=1
echo "Release compatibility evidence tests passed ($CHECKS cases)."
