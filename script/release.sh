#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
usage: $0 --preflight|--release
--preflight validates the candidate offline without credentials or a build.
--release fetches origin tags, requires a clean, pushed default-branch commit,
builds, signs, notarizes, verifies, and atomically publishes release artifacts.
Environment: TASKSCOPE_BUNDLE_ID (public identifier), TASKSCOPE_RELEASE_ARCHS=arm64,
TASKSCOPE_CODE_SIGN_IDENTITY (Developer ID name or SHA-1),
TASKSCOPE_EXPECTED_TEAM_ID, TASKSCOPE_NOTARY_KEYCHAIN_PROFILE,
TASKSCOPE_FIRST_RELEASE=1 (acknowledge no prior release tags),
TASKSCOPE_KEEP_RELEASE_WORK=1 (retain failed work for diagnosis).
Failed work is removed by default; notary JSON diagnostics are retained separately.
Work kept by earlier failed runs is removed when the next full release starts,
unless TASKSCOPE_KEEP_RELEASE_WORK=1.
EOF
}
[[ $# -eq 1 ]] || { usage >&2; exit 2; }
case "$1" in -h|--help) usage; exit 0 ;; esac
MODE="$1"
case "$MODE" in
  --release|release)
    ;;
  --preflight|preflight)
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/packaging_common.sh"
taskscope_clear_git_environment

APP_NAME="TaskScope"
MIN_SYSTEM_VERSION=""
BUNDLE_ID="$(taskscope_resolve_bundle_id)"
APP_VERSION="$(taskscope_read_release_value "$ROOT_DIR/VERSION" "version")"
APP_BUILD_NUMBER="$(taskscope_read_release_value "$ROOT_DIR/BUILD_NUMBER" "build number")"
RELEASE_ARCHS="${TASKSCOPE_RELEASE_ARCHS:-arm64}"
DIST_DIR="$ROOT_DIR/dist"
RELEASE_ROOT="$DIST_DIR/releases"
BASE_NAME="$APP_NAME-$APP_VERSION-$APP_BUILD_NUMBER-macOS-arm64"
FINAL_DIR="$RELEASE_ROOT/$BASE_NAME"
RELEASE_LOCK="$DIST_DIR/.$APP_NAME.release.lock"
RELEASE_LOCK_ACQUIRED=0
WORK_DIR=""
KEEP_RELEASE_WORK="${TASKSCOPE_KEEP_RELEASE_WORK:-0}"
# Set only where a full release deliberately finishes; see cleanup_release.
RELEASE_FINISHED=0

fail() {
  echo "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required release tool is unavailable: $1"
}

compatibility_failure() {
  echo "GlobalProtect lifecycle compatibility unverified: $*" >&2
  echo "Collect authorized lifecycle evidence using GLOBALPROTECT_COMPATIBILITY.md#machine-checkable-release-evidence, then rerun preflight." >&2
  fail "Until that evidence passes, retain source/development-only scope and the unverified notice in release notes; do not publish an app binary."
}

validate_compatibility_file() {
  local relative_path="$1"
  local component
  local current="$ROOT_DIR"
  local -a components

  # Only repository files are evidence. Never follow symlinks or accept paths
  # outside the checkout, including through a symlinked parent directory.
  [[ "$relative_path" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ \
    && "/$relative_path/" != *"/../"* \
    && "/$relative_path/" != *"/./"* \
    && "$relative_path" != *"//"* ]] \
    || compatibility_failure "Invalid evidence path '$relative_path'; use a repository-relative path without dot segments."
  IFS=/ read -r -a components <<< "$relative_path"
  for component in "${components[@]}"; do
    current="$current/$component"
    [[ ! -L "$current" ]] \
      || compatibility_failure "Evidence must not use symlinks: $relative_path"
  done
  [[ -f "$current" && -r "$current" && -s "$current" ]] \
    || compatibility_failure "Missing, unreadable, or empty evidence file: $relative_path"
  git -C "$ROOT_DIR" ls-files --error-unmatch -- "$relative_path" >/dev/null 2>&1 \
    || compatibility_failure "Evidence file is not tracked: $relative_path. Review and git add the redacted file."
}

validate_compatibility_evidence() {
  local evidence_dir="Evidence/GlobalProtect/lifecycle/$APP_VERSION-$APP_BUILD_NUMBER"
  local manifest
  local parsed
  local key
  local value
  local revision
  local count=0
  local nested
  local artifact_hash
  local artifact_hashes
  local environments=""
  local environment
  local test_date
  local normalized_date
  local revision_date
  local earliest_date
  local LC_ALL=C

  # A misplaced manifest must not silently bypass the gate, including a
  # tracked manifest that is currently deleted from the working tree.
  nested="$(git -C "$ROOT_DIR" ls-files -- "$evidence_dir/*/*.evidence")"
  if [[ -d "$ROOT_DIR/$evidence_dir" ]]; then
    nested="${nested}$(find "$ROOT_DIR/$evidence_dir" -mindepth 2 -name '*.evidence' -print -quit)"
  fi
  [[ -z "$nested" ]] || compatibility_failure "Place each manifest directly in $evidence_dir/: $nested"

  # Deliberately no environment override or skip flag: simulations and the
  # historical read-only report cannot satisfy a public-binary release gate.
  for manifest in "$ROOT_DIR/$evidence_dir/"*.evidence; do
    [[ -e "$manifest" || -L "$manifest" ]] || continue
    validate_compatibility_file "${manifest#"$ROOT_DIR/"}"
    if ! parsed="$(LC_ALL=C awk -v version="$APP_VERSION" -v build="$APP_BUILD_NUMBER" \
      -v bundle_id="$BUNDLE_ID" '
      function problem(message) {
        print FILENAME ": " message > "/dev/stderr"
        invalid = 1
      }
      function expect(key, expected) {
        if (values[key] != expected) problem(key " must be " expected ".")
      }
      BEGIN {
        n = split("schema_version evidence_kind test_date taskscope_version taskscope_build source_revision bundle_id signing_kind install_method macos_version macos_build architecture globalprotect_version agent_layout persistence_event coverage_gaps manual_results", keys, " ")
        for (i = 1; i <= n; i++) required[keys[i]] = 1
        step_count = split("baseline keep_off relaunch persistence keep_off_disabled open protected_service vpn managed_policy", steps, " ")
        for (i = 1; i <= step_count; i++) required["result_" steps[i]] = 1
        report_count = 6
        for (i = 1; i <= report_count; i++) required["report_" steps[i]] = 1
      }
      FNR == 1 && substr($0, 1, 3) == "\357\273\277" {
        problem("line 1: UTF-8 BOM is not supported; save UTF-8 without a BOM.")
        format_invalid = 1
        exit
      }
      /\r$/ {
        problem("line " FNR ": CRLF line endings are not supported; save with LF line endings.")
        format_invalid = 1
        exit
      }
      /^#/ || /^[[:space:]]*$/ { next }
      {
        separator = index($0, "=")
        key = substr($0, 1, separator - 1)
        value = substr($0, separator + 1)
        if (!separator || !(key in required)) {
          problem("line " FNR ": unknown field or malformed key=value record.")
          next
        }
        if (key in values) problem("Duplicate field: " key ".")
        if (value == "" || value ~ /[[:space:]]/) problem(key " must be a nonempty value without whitespace.")
        values[key] = value
      }
      END {
        if (format_invalid) exit 1
        for (key in required) if (!(key in values)) problem("Missing required field: " key ".")
        expect("schema_version", "1")
        expect("evidence_kind", "authorized-lifecycle")
        expect("taskscope_version", version)
        expect("taskscope_build", build)
        expect("bundle_id", bundle_id)
        expect("architecture", "arm64")
        expect("coverage_gaps", "none")
        if (values["test_date"] !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) problem("test_date must use YYYY-MM-DD.")
        if (values["source_revision"] !~ /^[0-9a-f]{40}$/) problem("source_revision must be a full lowercase Git commit SHA.")
        if (values["signing_kind"] !~ /^(ad-hoc|apple-development|developer-id)$/) problem("signing_kind must be ad-hoc, apple-development, or developer-id.")
        if (values["install_method"] !~ /^(staged-bundle|local-install|downloaded-archive)$/) problem("install_method must be staged-bundle, local-install, or downloaded-archive.")
        if (values["macos_version"] !~ /^[0-9]+\.[0-9]+(\.[0-9]+)?$/) problem("macos_version must be a numeric macOS version.")
        if (values["macos_build"] !~ /^[0-9]+[A-Z][0-9]+[a-z]?$/) problem("macos_build must be an Apple build identifier.")
        if (values["globalprotect_version"] !~ /^[0-9]+(\.[0-9]+){1,3}(-[0-9]+)?$/) problem("globalprotect_version must identify the tested version, including its suffix when present.")
        if (values["agent_layout"] !~ /^(pangpa-only|pangpa-and-pangps)$/) problem("agent_layout must be pangpa-only or pangpa-and-pangps.")
        if (values["persistence_event"] !~ /^(logout-login|reboot)$/) problem("persistence_event must be logout-login or reboot.")
        for (i = 1; i <= step_count; i++) expect("result_" steps[i], "pass")
        reports[values["manual_results"]] = 1
        if (values["manual_results"] ~ /\.evidence$/) problem("An evidence artifact cannot be a .evidence manifest.")
        for (i = 1; i <= report_count; i++) {
          path = values["report_" steps[i]]
          if (path in reports) problem("Each lifecycle snapshot needs a distinct report path: " path ".")
          if (path ~ /\.evidence$/) problem("An evidence artifact cannot be a .evidence manifest.")
          reports[path] = 1
        }
        if (invalid) exit 1
        print "source_revision=" values["source_revision"]
        print "test_date=" values["test_date"]
        print "environment=" values["macos_build"] ":" values["architecture"] ":" values["globalprotect_version"] ":" values["agent_layout"] ":" values["persistence_event"]
        print "artifact=" values["manual_results"]
        for (i = 1; i <= report_count; i++) print "artifact=" values["report_" steps[i]]
      }
    ' "$manifest")"; then
      compatibility_failure "Incomplete or invalid lifecycle manifest: ${manifest#"$ROOT_DIR/"}"
    fi

    artifact_hashes=""
    while IFS='=' read -r key value; do
      if [[ "$key" == source_revision ]]; then
        revision="$value"
        git -C "$ROOT_DIR" merge-base --is-ancestor "$revision" HEAD 2>/dev/null \
          || compatibility_failure "source_revision $revision must be an existing ancestor of HEAD (or HEAD itself)."
        # Evidence can be committed after testing without a circular commit SHA.
        # Only evidence and its three release documents may change afterward.
        git -C "$ROOT_DIR" diff --quiet "$revision" -- . \
          ':(exclude)Evidence/GlobalProtect' \
          ':(exclude)GLOBALPROTECT_COMPATIBILITY.md' \
          ':(exclude)RELEASE.md' ':(exclude)CHANGELOG.md' \
          || compatibility_failure "Candidate content differs from tested source_revision $revision. Retest the current candidate and update the manifest."
      elif [[ "$key" == test_date ]]; then
        test_date="$value"
        normalized_date="$(date -j -u -f '%Y-%m-%d %H:%M:%S' "$test_date 00:00:00" +%F 2>/dev/null)" \
          || compatibility_failure "test_date must be a valid calendar date: $test_date"
        [[ "$normalized_date" == "$test_date" ]] \
          || compatibility_failure "test_date must be a valid calendar date: $test_date"
        [[ ! "$test_date" > "$(date -u +%F)" ]] \
          || compatibility_failure "test_date must not be in the future: $test_date"
        revision_date="$(git -C "$ROOT_DIR" show -s --format=%as "$revision")"
        earliest_date="$(date -j -u -v-1d -f '%Y-%m-%d %H:%M:%S' "$revision_date 00:00:00" +%F)"
        [[ ! "$test_date" < "$earliest_date" ]] \
          || compatibility_failure "test_date precedes source_revision author date (allowing one day for time zones)."
      elif [[ "$key" == environment ]]; then
        environment="$value"
        if grep -Fxq "$environment" <<< "$environments"; then
          compatibility_failure "Duplicate tested environment in ${manifest#"$ROOT_DIR/"}: $environment"
        fi
        environments="${environments}${environment}
"
      else
        [[ "$value" == "$evidence_dir/"* ]] \
          || compatibility_failure "Artifact '$value' must be retained under $evidence_dir/."
        validate_compatibility_file "$value"
        artifact_hash="$(git -C "$ROOT_DIR" hash-object -- "$value")"
        if grep -Fxq "$artifact_hash" <<< "$artifact_hashes"; then
          compatibility_failure "Evidence artifacts must have distinct contents: $value"
        fi
        artifact_hashes="${artifact_hashes}${artifact_hash}
"
      fi
    done <<< "$parsed"
    count=$((count + 1))
  done

  [[ "$count" -gt 0 ]] \
    || compatibility_failure "No lifecycle manifests found at $evidence_dir/*.evidence. Fixtures and read-only observations are insufficient."
  echo "GlobalProtect lifecycle evidence gate passed ($count tested environment(s)); claims remain limited to the recorded combinations."
}

validate_credential_independent_inputs() {
  if [[ "$BUNDLE_ID" == com.local.* ]]; then
    fail "Public releases cannot use the development bundle identifier '$BUNDLE_ID'."
  fi
  if [[ ! "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    fail "Invalid VERSION value: $APP_VERSION"
  fi
  if [[ ! "$APP_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    fail "Invalid BUILD_NUMBER value: $APP_BUILD_NUMBER"
  fi
  if [[ "$RELEASE_ARCHS" != "arm64" ]]; then
    fail "The verified first-release architecture policy is arm64 only."
  fi
  if [[ "$(uname -m)" != "arm64" ]]; then
    fail "The arm64 release must be built on an arm64 Mac."
  fi

  require_command awk
  require_command git

  # Build numbers must increase for every distributed artifact: refuse to
  # release a build number that is not greater than every v* tag's.
  taskscope_validate_build_number_history "$ROOT_DIR" "$APP_BUILD_NUMBER" || exit 1

  if git -C "$ROOT_DIR" rev-parse -q --verify "refs/tags/v$APP_VERSION" >/dev/null; then
    fail "Release tag v$APP_VERSION already exists; bump VERSION and add its CHANGELOG.md section."
  fi
  [[ ! -e "$FINAL_DIR" && ! -L "$FINAL_DIR" ]] \
    || fail "Refusing to overwrite existing release output: $FINAL_DIR"

  # The release notes must exist before the artifact does. Match the version
  # literally, and require a complete heading rather than a version prefix.
  if ! awk -v heading="## [$APP_VERSION]" '$0 == heading || index($0, heading " - ") == 1 { found = 1 } END { exit !found }' "$ROOT_DIR/CHANGELOG.md"; then
    fail "CHANGELOG.md lacks a '## [$APP_VERSION]' heading for this release."
  fi

  if ! awk '
    /^## \[Unreleased\]/ { in_unreleased = 1; next }
    /^## / { in_unreleased = 0 }
    in_unreleased && /^[[:space:]]*[-*+] / { pending = 1 }
    END { exit pending ? 1 : 0 }
  ' "$ROOT_DIR/CHANGELOG.md"; then
    fail "CHANGELOG.md still has Unreleased entries; move candidate notes into the versioned release section."
  fi

  validate_compatibility_evidence

  require_command codesign
  require_command ditto
  require_command dwarfdump
  require_command lipo
  require_command plutil
  require_command security
  require_command shasum
  require_command shlock
  require_command spctl
  require_command swift
  require_command xcodebuild
  require_command xcrun

  taskscope_require_xcode
  MIN_SYSTEM_VERSION="$(taskscope_resolve_minimum_system_version "$ROOT_DIR")" || exit 1
  xcrun --find appintentsmetadataprocessor >/dev/null
  xcrun --find dsymutil >/dev/null
  xcrun --find notarytool >/dev/null
  xcrun --find stapler >/dev/null
}

cleanup_release() {
  local exit_code="$?"

  # bash 3.2 runs the EXIT trap with status 0 after a `set -u` abort, so a
  # release that stopped before it finished must still fail.
  if [[ "$exit_code" -eq 0 && "${RELEASE_FINISHED:-0}" -ne 1 ]]; then
    echo "The release stopped before it finished." >&2
    exit_code=1
  fi

  if [[ "$RELEASE_LOCK_ACQUIRED" -eq 1 ]]; then
    taskscope_release_lock "$RELEASE_LOCK"
  fi
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    if [[ "$exit_code" -ne 0 && "$KEEP_RELEASE_WORK" == 1 ]]; then
      echo "Release work preserved for diagnosis at $WORK_DIR" >&2
    else
      if [[ "$exit_code" -ne 0 ]]; then
        local diagnostics=""
        local log
        for log in "$WORK_DIR/"*-notary.json "$WORK_DIR/"*-notary-log.json; do
          [[ -f "$log" ]] || continue
          if [[ -z "$diagnostics" ]]; then
            diagnostics="$(mktemp -d "$DIST_DIR/$APP_NAME-notary-diagnostics.XXXXXX")"
          fi
          cp "$log" "$diagnostics/"
        done
        [[ -z "$diagnostics" ]] || echo "Notary diagnostics retained at $diagnostics" >&2
      fi
      rm -rf "$WORK_DIR"
    fi
  fi

  return "$exit_code"
}

verify_release_signature() {
  local bundle="$1"
  local executable="$bundle/Contents/MacOS/$APP_NAME"
  local signature_info
  local entitlements
  local build_version

  [[ -d "$bundle" ]] || fail "Release verification failed: missing $bundle"
  [[ -x "$executable" ]] || fail "Release verification failed: missing executable."
  # The same Info.plist and App Intents check that staging runs, including the
  # App Intents names and phrases in script/expected_intents.json.
  taskscope_verify_bundle_metadata full "$bundle" "$ROOT_DIR" "$BUNDLE_ID" \
    "$APP_VERSION" "$APP_BUILD_NUMBER" "$MIN_SYSTEM_VERSION" \
    || fail "Release verification failed: the bundle metadata does not match this checkout."
  [[ "$(lipo -archs "$executable")" == "arm64" ]] \
    || fail "Release verification failed: expected exactly arm64."
  # Captured first: grep -q leaving a pipe early could fail it under pipefail.
  build_version="$(/usr/bin/vtool -show-build "$executable" 2>/dev/null || true)"
  /usr/bin/grep -Eq "minos[[:space:]]+$MIN_SYSTEM_VERSION\$" <<< "$build_version" \
    || fail "Release verification failed: binary deployment target mismatch."

  taskscope_verify_binary_paths "$executable" || fail "Release verification failed: unsafe runtime search paths."
  taskscope_verify_no_debug_paths "$executable" || exit 1
  /usr/bin/codesign --verify --deep --strict --verbose=4 "$bundle"

  signature_info="$(/usr/bin/codesign -dvvv "$bundle" 2>&1)"
  /usr/bin/grep -Eq 'flags=.*runtime' <<< "$signature_info" \
    || fail "Release verification failed: hardened runtime is absent."
  /usr/bin/grep -Fq "TeamIdentifier=$TASKSCOPE_EXPECTED_TEAM_ID" <<< "$signature_info" \
    || fail "Release verification failed: signing Team ID mismatch."

  entitlements="$(/usr/bin/codesign -d --entitlements - --xml "$bundle" 2>/dev/null || true)"
  if /usr/bin/grep -q '<key>' <<< "$entitlements"; then
    fail "Release verification failed: the release unexpectedly contains entitlements."
  fi
}

verify_notarized_bundle() {
  local bundle="$1"

  verify_release_signature "$bundle"
  xcrun stapler validate "$bundle"
  /usr/sbin/spctl -a -vvv -t exec "$bundle"
}

validate_credential_independent_inputs

if [[ "$MODE" == "--preflight" || "$MODE" == "preflight" ]]; then
  echo "Credential-independent release preflight passed."
  echo "Version: $APP_VERSION ($APP_BUILD_NUMBER)"
  echo "Bundle identifier: $BUNDLE_ID"
  echo "Architecture: arm64"
  for required_name in \
    TASKSCOPE_CODE_SIGN_IDENTITY \
    TASKSCOPE_EXPECTED_TEAM_ID \
    TASKSCOPE_NOTARY_KEYCHAIN_PROFILE; do
    if [[ -z "${!required_name:-}" ]]; then
      echo "Full release still requires $required_name."
    fi
  done
  exit 0
fi

[[ -n "${TASKSCOPE_CODE_SIGN_IDENTITY:-}" ]] \
  || fail "TASKSCOPE_CODE_SIGN_IDENTITY is required."
[[ "${TASKSCOPE_EXPECTED_TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]] \
  || fail "TASKSCOPE_EXPECTED_TEAM_ID must be a 10-character Apple Team ID."
[[ -n "${TASKSCOPE_NOTARY_KEYCHAIN_PROFILE:-}" ]] \
  || fail "TASKSCOPE_NOTARY_KEYCHAIN_PROFILE is required."

# Accept a name or SHA-1, then sign by SHA-1 so duplicate names are not ambiguous.
SIGNING_IDENTITY="$(taskscope_find_signing_identity "$TASKSCOPE_CODE_SIGN_IDENTITY")" \
  || fail "The requested Developer ID Application identity is not available with its private key."
[[ "${SIGNING_IDENTITY#* }" == "Developer ID Application:"* ]] \
  || fail "TASKSCOPE_CODE_SIGN_IDENTITY must name a Developer ID Application identity."
SIGNING_IDENTITY_HASH="${SIGNING_IDENTITY%% *}"

cd "$ROOT_DIR"
[[ -z "$(git status --porcelain --untracked-files=all)" ]] \
  || fail "Release builds require a clean Git worktree."

# Full releases refresh local history; preflight remains offline. Refuse a
# detached/side branch or a commit absent from the configured default upstream.
GIT_BRANCH="$(git symbolic-ref -q --short HEAD)" \
  || fail "Release builds require the default branch, not a detached HEAD."
GIT_DEFAULT_REMOTE_BRANCH="$(git symbolic-ref -q --short refs/remotes/origin/HEAD)" \
  || fail "Configure origin/HEAD to identify the default release branch."
[[ "$GIT_BRANCH" == "${GIT_DEFAULT_REMOTE_BRANCH#origin/}" ]] \
  || fail "Release builds require the default branch ${GIT_DEFAULT_REMOTE_BRANCH#origin/}."
git fetch --tags origin || fail "Could not fetch origin and release tags."
GIT_UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}')" \
  || fail "The release branch needs a configured upstream."
[[ "$GIT_UPSTREAM" == "$GIT_DEFAULT_REMOTE_BRANCH" ]] \
  || fail "The release upstream must be $GIT_DEFAULT_REMOTE_BRANCH."
GIT_REMOTE_HEAD="$(git rev-parse "$GIT_UPSTREAM")"
[[ "$(git rev-parse HEAD)" == "$GIT_REMOTE_HEAD" ]] \
  || fail "Release HEAD must match its fetched upstream; push local commits and resolve divergence first."
GIT_REMOTE_URL="$(git remote get-url origin)"
# Refresh the tag gates after fetching; locally missing tags cannot be ignored.
taskscope_validate_build_number_history "$ROOT_DIR" "$APP_BUILD_NUMBER" || exit 1
if git rev-parse -q --verify "refs/tags/v$APP_VERSION" >/dev/null; then
  fail "Release tag v$APP_VERSION already exists; bump VERSION."
fi

xcrun notarytool history \
  --keychain-profile "$TASKSCOPE_NOTARY_KEYCHAIN_PROFILE" \
  --output-format json >/dev/null

mkdir -p "$DIST_DIR" "$RELEASE_ROOT"
taskscope_acquire_lock "$RELEASE_LOCK" "release process"
RELEASE_LOCK_ACQUIRED=1
trap 'cleanup_release; exit $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ ! -e "$FINAL_DIR" ]] \
  || fail "Refusing to overwrite existing release output: $FINAL_DIR"

# Work kept by earlier failed runs holds signed apps and archives. The release
# lock guarantees that none of it belongs to a running release.
if [[ "$KEEP_RELEASE_WORK" != 1 ]]; then
  for stale_work in "$DIST_DIR/.$APP_NAME.release."*; do
    [[ -d "$stale_work" && ! -L "$stale_work" ]] || continue
    rm -rf "$stale_work"
    echo "Removed earlier release work at $stale_work" >&2
  done
fi

WORK_DIR="$(mktemp -d "$DIST_DIR/.$APP_NAME.release.XXXXXX")"
WORK_APP="$WORK_DIR/$APP_NAME.app"
WORK_DSYM="$WORK_DIR/$APP_NAME.dSYM"
SUBMISSION_ZIP="$WORK_DIR/$BASE_NAME-notary-submission.zip"
NOTARY_RESULT="$WORK_DIR/$BASE_NAME-notary.json"
OUTPUT_DIR="$WORK_DIR/output"
ROUND_TRIP_DIR="$WORK_DIR/round-trip"
FINAL_ZIP="$OUTPUT_DIR/$BASE_NAME.zip"
DSYM_ZIP="$OUTPUT_DIR/$BASE_NAME-dSYM.zip"
PROVENANCE="$OUTPUT_DIR/$BASE_NAME-provenance.txt"
CHECKSUMS="$OUTPUT_DIR/SHA256SUMS"

TASKSCOPE_SIGNING_STYLE=distribution \
TASKSCOPE_BUNDLE_ID="$BUNDLE_ID" \
TASKSCOPE_CODE_SIGN_IDENTITY="$SIGNING_IDENTITY_HASH" \
TASKSCOPE_OUTPUT_DIR="$WORK_DIR/stage.noindex" \
TASKSCOPE_VERIFIED_BUNDLE_COPY="$WORK_APP" \
TASKSCOPE_DSYM_COPY="$WORK_DSYM" \
BUILD_CONFIGURATION=release \
  "$ROOT_DIR/script/build_and_run.sh" --stage >/dev/null

[[ -z "$(git status --porcelain --untracked-files=all)" ]] \
  || fail "Release build changed the Git worktree; refusing to publish."

BINARY_UUIDS="$(dwarfdump --uuid "$WORK_APP/Contents/MacOS/$APP_NAME" | awk '{print $2, $3}')"
DSYM_UUIDS="$(dwarfdump --uuid "$WORK_DSYM" | awk '{print $2, $3}')"
[[ -n "$BINARY_UUIDS" && "$BINARY_UUIDS" == "$DSYM_UUIDS" ]] \
  || fail "Release verification failed: app and dSYM UUIDs differ."

verify_release_signature "$WORK_APP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$WORK_APP" "$SUBMISSION_ZIP"

xcrun notarytool submit "$SUBMISSION_ZIP" \
  --keychain-profile "$TASKSCOPE_NOTARY_KEYCHAIN_PROFILE" \
  --wait --output-format json > "$NOTARY_RESULT"

NOTARY_STATUS="$(plutil -extract status raw -o - "$NOTARY_RESULT" 2>/dev/null || true)"
NOTARY_ID="$(plutil -extract id raw -o - "$NOTARY_RESULT" 2>/dev/null || true)"
if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
  if [[ -n "$NOTARY_ID" ]]; then
    xcrun notarytool log \
      --keychain-profile "$TASKSCOPE_NOTARY_KEYCHAIN_PROFILE" \
      "$NOTARY_ID" \
      "$WORK_DIR/$BASE_NAME-notary-log.json" || true
  fi
  fail "Notarization was not accepted (status: ${NOTARY_STATUS:-unknown})."
fi

xcrun stapler staple "$WORK_APP"
verify_notarized_bundle "$WORK_APP"

mkdir -p "$OUTPUT_DIR" "$ROUND_TRIP_DIR"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$WORK_APP" "$FINAL_ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$WORK_DSYM" "$DSYM_ZIP"
/usr/bin/ditto "$NOTARY_RESULT" "$OUTPUT_DIR/$(basename "$NOTARY_RESULT")"

GIT_COMMIT="$(git rev-parse HEAD)"
XCODE_VERSION="$(xcodebuild -version | /usr/bin/awk '{printf "%s%s", separator, $0; separator="; "}')"
SWIFT_VERSION="$(swift --version | /usr/bin/awk 'NR == 1 { print; exit }')"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
{
  printf 'product=%s\n' "$APP_NAME"
  printf 'version=%s\n' "$APP_VERSION"
  printf 'build=%s\n' "$APP_BUILD_NUMBER"
  printf 'bundle_id=%s\n' "$BUNDLE_ID"
  printf 'architecture=arm64\n'
  printf 'minimum_macos=%s\n' "$MIN_SYSTEM_VERSION"
  printf 'git_commit=%s\n' "$GIT_COMMIT"
  printf 'git_branch=%s\n' "$GIT_BRANCH"
  printf 'git_upstream=%s\n' "$GIT_UPSTREAM"
  printf 'git_remote_url=%s\n' "$GIT_REMOTE_URL"
  printf 'git_remote_head=%s\n' "$GIT_REMOTE_HEAD"
  printf 'xcode=%s\n' "$XCODE_VERSION"
  printf 'swift=%s\n' "$SWIFT_VERSION"
  printf 'macos_sdk=%s\n' "$SDK_VERSION"
  printf 'signing_type=Developer ID Application\n'
  printf 'team_id=%s\n' "$TASKSCOPE_EXPECTED_TEAM_ID"
  printf 'notary_submission_id=%s\n' "$NOTARY_ID"
  printf 'notary_status=%s\n' "$NOTARY_STATUS"
  printf 'binary_uuids=%s\n' "$BINARY_UUIDS"
} > "$PROVENANCE"

(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$(basename "$FINAL_ZIP")" \
    "$(basename "$DSYM_ZIP")" \
    "$(basename "$PROVENANCE")" \
    "$(basename "$NOTARY_RESULT")" > "$(basename "$CHECKSUMS")"
  shasum -a 256 -c "$(basename "$CHECKSUMS")"
)

/usr/bin/ditto -x -k "$FINAL_ZIP" "$ROUND_TRIP_DIR"
verify_notarized_bundle "$ROUND_TRIP_DIR/$APP_NAME.app"

mv "$OUTPUT_DIR" "$FINAL_DIR"

echo "Created verified release artifacts in $FINAL_DIR"
RELEASE_FINISHED=1
