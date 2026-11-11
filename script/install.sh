#!/usr/bin/env bash
set -euo pipefail

OPEN_AFTER_INSTALL=1
APP_NAME="TaskScope"

usage() {
  cat <<EOF
usage: $0 [--no-open]
Default: build, install, and open TaskScope. --no-open installs without launching.
Environment: DEST_DIR (default /Applications), TASKSCOPE_BUNDLE_ID,
TASKSCOPE_CODE_SIGN_IDENTITY (name, SHA-1, or - for ad-hoc),
TASKSCOPE_SIGNING_STYLE=development|distribution, BUILD_CONFIGURATION,
TASKSCOPE_OUTPUT_DIR (absolute staging directory), TASKSCOPE_SKIP_BUILD=1
(reuse the staged bundle), TASKSCOPE_INSTALL_FAIL_AT (transaction test hook).
Builds require Xcode 26 or later and can take several minutes.
EOF
}
[[ $# -le 1 ]] || { usage >&2; exit 2; }
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --no-open)
    OPEN_AFTER_INSTALL=0
    ;;
  "")
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/packaging_common.sh"
BUNDLE_ID="$(taskscope_resolve_bundle_id)"
DEST_DIR="${DEST_DIR:-/Applications}"
DEST_BUNDLE="$DEST_DIR/$APP_NAME.app"
STAGING_DIR="${TASKSCOPE_OUTPUT_DIR:-$ROOT_DIR/dist/build.noindex}"
[[ "$STAGING_DIR" == /* ]] || { echo "TASKSCOPE_OUTPUT_DIR must be absolute." >&2; exit 2; }
STAGED_BUNDLE="$STAGING_DIR/$APP_NAME.app"
INSTALLING_BUNDLE="$DEST_DIR/.$APP_NAME.installing.$$"
BACKUP_BUNDLE="$DEST_DIR/.$APP_NAME.backup.$$"
INSTALL_LOCK="$DEST_DIR/.$APP_NAME.install.lock"
INSTALL_LOCK_ACQUIRED=0
PACKAGING_LOCK="$STAGING_DIR/.$APP_NAME.package.lock"
PACKAGING_LOCK_ACQUIRED=0
INSTALL_STATE="preparing"
DESTINATION_STOPPED=0
# Set only where the installer deliberately finishes; see cleanup_install.
INSTALL_FINISHED=0

cleanup_install() {
  local exit_code="$?"

  # bash 3.2 runs the EXIT trap with status 0 after a `set -u` abort, so a
  # run that stopped before a deliberate finish must still fail and roll back.
  if [[ "$exit_code" -eq 0 && "${INSTALL_FINISHED:-0}" -ne 1 ]]; then
    echo "The installer stopped before it finished." >&2
    exit_code=1
  fi
  if [[ "$exit_code" -ne 0 ]]; then
    case "$INSTALL_STATE" in
      backing-up|backed-up|replacing|replaced)
        if [[ -d "$BACKUP_BUNDLE" ]]; then
          rm -rf "$DEST_BUNDLE"
          mv "$BACKUP_BUNDLE" "$DEST_BUNDLE"
          echo "Install failed; restored the previous $DEST_BUNDLE." >&2
        fi
        ;;
      installed)
        rm -rf "$DEST_BUNDLE"
        echo "Install failed; removed the incomplete $DEST_BUNDLE." >&2
        ;;
    esac
  fi

  if [[ "$exit_code" -ne 0 && "${DESTINATION_STOPPED:-0}" -eq 1 ]]; then
    echo "TaskScope was quit for the upgrade and has not been restarted." >&2
  fi
  if [[ -d "$INSTALLING_BUNDLE" ]]; then
    rm -rf "$INSTALLING_BUNDLE"
  fi

  if [[ "$INSTALL_STATE" == "complete" && -d "$BACKUP_BUNDLE" ]]; then
    rm -rf "$BACKUP_BUNDLE"
  fi
  if [[ "$INSTALL_LOCK_ACQUIRED" -eq 1 ]]; then
    taskscope_release_lock "$INSTALL_LOCK"
  fi
  if [[ "$PACKAGING_LOCK_ACQUIRED" -eq 1 ]]; then
    taskscope_release_lock "$PACKAGING_LOCK"
  fi

  exit "$exit_code"
}
trap cleanup_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail_if_requested() {
  local point="$1"
  if [[ "${TASKSCOPE_INSTALL_FAIL_AT:-}" == "$point" ]]; then
    echo "Injected install failure at $point." >&2
    return 1
  fi
}

stop_destination_app() {
  local executable="$DEST_BUNDLE/Contents/MacOS/$APP_NAME"

  if [[ ! -x "$executable" ]]; then
    return 0
  fi

  # A failed stop reports its own error; only a confirmed stop is announced
  # again if a later step fails and the app stays quit.
  taskscope_stop_processes_for_executable "$executable"
  DESTINATION_STOPPED="$TASKSCOPE_STOPPED_PROCESSES"
}

verify_install_bundle_metadata() {
  local bundle="$1"
  local key
  local expected
  local actual

  for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion; do
    case "$key" in
      CFBundleIdentifier) expected="$BUNDLE_ID" ;;
      CFBundleShortVersionString) expected="$APP_VERSION" ;;
      CFBundleVersion) expected="$APP_BUILD_NUMBER" ;;
    esac
    actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$bundle/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$actual" != "$expected" ]]; then
      echo "Refusing to install $bundle: $key is '$actual' (expected '$expected')." >&2
      return 1
    fi
  done
}

if [[ ! -d "$DEST_DIR" ]]; then
  echo "Install destination does not exist: $DEST_DIR" >&2
  exit 1
fi

if [[ ! -w "$DEST_DIR" ]]; then
  echo "Install destination is not writable: $DEST_DIR" >&2
  echo "Run with DEST_DIR set to a writable folder, or install manually with admin privileges." >&2
  exit 1
fi

taskscope_acquire_lock "$INSTALL_LOCK" installer
INSTALL_LOCK_ACQUIRED=1
taskscope_recover_bundles "$DEST_BUNDLE" "$DEST_DIR/.$APP_NAME.backup." "$DEST_DIR/.$APP_NAME.installing."

# Refuse foreign objects before a build or any process stop. Symlinked bundles
# are not owned by this installer, even when their target looks like TaskScope.
if [[ -e "$DEST_BUNDLE" || -L "$DEST_BUNDLE" ]]; then
  EXISTING_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$DEST_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
  if [[ ! -d "$DEST_BUNDLE" || -L "$DEST_BUNDLE" || "$EXISTING_ID" != "$BUNDLE_ID" ]]; then
    echo "Refusing to replace $DEST_BUNDLE because it is not a $BUNDLE_ID bundle directory." >&2
    exit 1
  fi
fi
if [[ "$OPEN_AFTER_INSTALL" -eq 1 ]]; then
  taskscope_require_no_other_app_instance "$DEST_BUNDLE" "$BUNDLE_ID"
fi

if [[ "${TASKSCOPE_SKIP_BUILD:-0}" != "1" ]]; then
  echo "Building release bundle (this can take several minutes)…"
  "$ROOT_DIR/script/build_and_run.sh" --stage >/dev/null
fi

# The stage child releases its lock on exit. Acquire it again before reading
# the shared bundle, including when the caller deliberately skips the build.
mkdir -p "$(dirname "$PACKAGING_LOCK")"
taskscope_acquire_lock "$PACKAGING_LOCK" "packaging process"
PACKAGING_LOCK_ACQUIRED=1
APP_VERSION="$(taskscope_read_release_value "$ROOT_DIR/VERSION" "version")"
APP_BUILD_NUMBER="$(taskscope_read_release_value "$ROOT_DIR/BUILD_NUMBER" "build number")"

if [[ ! -d "$STAGED_BUNDLE" ]]; then
  echo "Build did not produce $STAGED_BUNDLE" >&2
  exit 1
fi

/usr/bin/codesign --verify --deep --strict "$STAGED_BUNDLE"

verify_install_bundle_metadata "$STAGED_BUNDLE"

if [[ -d "$DEST_BUNDLE" ]]; then
  EXISTING_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$DEST_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$EXISTING_ID" != "$BUNDLE_ID" ]]; then
    echo "Refusing to replace $DEST_BUNDLE because it is not $BUNDLE_ID." >&2
    exit 1
  fi
fi

rm -rf "$INSTALLING_BUNDLE" "$BACKUP_BUNDLE"
/usr/bin/ditto "$STAGED_BUNDLE" "$INSTALLING_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$INSTALLING_BUNDLE"
verify_install_bundle_metadata "$INSTALLING_BUNDLE"
fail_if_requested "after_copy"

# The private copy is now validated; destination replacement needs only the
# installer lock and no longer depends on the shared staged bundle.
taskscope_release_lock "$PACKAGING_LOCK"
PACKAGING_LOCK_ACQUIRED=0

stop_destination_app

if [[ -d "$DEST_BUNDLE" ]]; then
  INSTALL_STATE="backing-up"
  mv "$DEST_BUNDLE" "$BACKUP_BUNDLE"
  INSTALL_STATE="backed-up"
fi
fail_if_requested "after_backup"

if [[ "$INSTALL_STATE" == "backed-up" ]]; then
  INSTALL_STATE="replacing"
else
  INSTALL_STATE="installing"
fi
mv "$INSTALLING_BUNDLE" "$DEST_BUNDLE"
if [[ "$INSTALL_STATE" == "replacing" ]]; then
  INSTALL_STATE="replaced"
else
  INSTALL_STATE="installed"
fi
fail_if_requested "after_replace"

/usr/bin/codesign --verify --deep --strict "$DEST_BUNDLE"
verify_install_bundle_metadata "$DEST_BUNDLE"
fail_if_requested "after_verify"

INSTALL_STATE="complete"
if [[ -d "$BACKUP_BUNDLE" ]]; then
  rm -rf "$BACKUP_BUNDLE"
fi

if [[ "$OPEN_AFTER_INSTALL" -eq 1 ]]; then
  if ! taskscope_require_no_other_app_instance "$DEST_BUNDLE" "$BUNDLE_ID" \
    || ! /usr/bin/open "$DEST_BUNDLE"; then
    echo "Installed $DEST_BUNDLE; it could not be opened. Open it manually after resolving the launch conflict." >&2
    INSTALL_FINISHED=1
    exit 0
  fi
fi

echo "Installed $DEST_BUNDLE"
INSTALL_FINISHED=1
