#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"

case "$MODE" in
  run|--stage|stage|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
    ;;
  *)
    echo "usage: $0 [run|--stage|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-}"
PRODUCT_NAME="TaskScope"
APP_NAME="TaskScope"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/packaging_common.sh"
BUNDLE_ID="$(taskscope_resolve_bundle_id)"
# Keep the local build out of Spotlight beside the installed /Applications copy.
# Release archives still go to dist/releases through release.sh.
DIST_DIR="$ROOT_DIR/dist/build.noindex"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON="$APP_RESOURCES/AppIcon.icns"
VERSION_FILE="$ROOT_DIR/VERSION"
BUILD_NUMBER_FILE="$ROOT_DIR/BUILD_NUMBER"

# Prints "<SHA-1> <name>" for the signing identity, or "-" for ad-hoc signing.
# TASKSCOPE_CODE_SIGN_IDENTITY may be an identity name or its SHA-1.
resolve_code_sign_identity() {
  local requested="${TASKSCOPE_CODE_SIGN_IDENTITY:-}"

  if [[ -z "$requested" ]]; then
    requested="$(
      /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
        | /usr/bin/awk -F '"' '/Apple Development:/ { print $2; exit }'
    )"
  fi
  if [[ -z "$requested" || "$requested" == "-" ]]; then
    printf '%s' "-"
    return
  fi

  taskscope_find_signing_identity "$requested" || {
    echo "Code signing identity is not available with its private key: $requested" >&2
    return 1
  }
}

APP_VERSION="$(taskscope_read_release_value "$VERSION_FILE" "version")"
APP_BUILD_NUMBER="$(taskscope_read_release_value "$BUILD_NUMBER_FILE" "build number")"
CODE_SIGN_RECORD="$(resolve_code_sign_identity)"
CODE_SIGN_IDENTITY="${CODE_SIGN_RECORD%% *}"
CODE_SIGN_IDENTITY_NAME="${CODE_SIGN_RECORD#* }"
SIGNING_STYLE="${TASKSCOPE_SIGNING_STYLE:-development}"

if [[ ! "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "Invalid VERSION value: $APP_VERSION" >&2
  exit 1
fi

if [[ ! "$APP_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid BUILD_NUMBER value: $APP_BUILD_NUMBER" >&2
  exit 1
fi

if [[ -z "$BUILD_CONFIGURATION" ]]; then
  case "$MODE" in
    --debug|debug)
      BUILD_CONFIGURATION="debug"
      ;;
    *)
      BUILD_CONFIGURATION="release"
      ;;
  esac
fi

case "$BUILD_CONFIGURATION" in
  debug|release)
    ;;
  *)
    echo "BUILD_CONFIGURATION must be debug or release." >&2
    exit 2
    ;;
esac

case "$SIGNING_STYLE" in
  development)
    ;;
  distribution)
    if [[ "$CODE_SIGN_IDENTITY_NAME" != "Developer ID Application:"* ]]; then
      echo "Distribution packaging requires an explicit Developer ID Application identity." >&2
      exit 1
    fi
    ;;
  *)
    echo "TASKSCOPE_SIGNING_STYLE must be development or distribution." >&2
    exit 2
    ;;
esac

verify_plist_value() {
  local plist="$1"
  local key="$2"
  local expected="$3"
  local actual

  actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)"
  if [[ "$actual" != "$expected" ]]; then
    echo "Bundle verification failed: $key is '$actual' (expected '$expected')." >&2
    return 1
  fi
}

verify_bundle() {
  local bundle="$1"
  local contents="$bundle/Contents"
  local executable="$contents/MacOS/$APP_NAME"
  local plist="$contents/Info.plist"
  local icon="$contents/Resources/AppIcon.icns"
  local app_intents_metadata="$contents/Resources/Metadata.appintents"

  [[ -d "$bundle" ]] || {
    echo "Bundle verification failed: missing $bundle" >&2
    return 1
  }
  [[ -x "$executable" ]] || {
    echo "Bundle verification failed: missing executable $executable" >&2
    return 1
  }
  [[ -s "$icon" ]] || {
    echo "Bundle verification failed: missing icon $icon" >&2
    return 1
  }
  if ! /usr/bin/sips -g format "$icon" 2>/dev/null | /usr/bin/grep -q "format: icns"; then
    echo "Bundle verification failed: AppIcon.icns is not a valid ICNS image." >&2
    return 1
  fi
  verify_icon_members "$icon" || return 1

  /usr/bin/plutil -lint "$plist" >/dev/null
  verify_plist_value "$plist" "CFBundleExecutable" "$APP_NAME"
  verify_plist_value "$plist" "CFBundleIdentifier" "$BUNDLE_ID"
  verify_plist_value "$plist" "CFBundleShortVersionString" "$APP_VERSION"
  verify_plist_value "$plist" "CFBundleVersion" "$APP_BUILD_NUMBER"
  verify_plist_value "$plist" "LSMinimumSystemVersion" "$MIN_SYSTEM_VERSION"
  verify_plist_value "$plist" "CFBundleURLTypes:0:CFBundleURLSchemes:0" "taskscope"

  local obsolete_privacy_key
  for obsolete_privacy_key in NSAppleEventsUsageDescription NSServerUsageDescription; do
    if /usr/libexec/PlistBuddy -c "Print :$obsolete_privacy_key" "$plist" >/dev/null 2>&1; then
      echo "Bundle verification failed: obsolete $obsolete_privacy_key is present." >&2
      return 1
    fi
  done

  [[ -s "$app_intents_metadata/version.json" ]] || {
    echo "Bundle verification failed: App Intents version metadata is missing." >&2
    return 1
  }
  [[ -s "$app_intents_metadata/extract.actionsdata" ]] || {
    echo "Bundle verification failed: App Intents action metadata is missing." >&2
    return 1
  }
  local metadata_version
  local metadata_tools_version
  metadata_version="$(
    /usr/bin/plutil -extract version raw -o - "$app_intents_metadata/version.json" 2>/dev/null || true
  )"
  metadata_tools_version="$(
    /usr/bin/plutil -extract toolsVersion raw -o - "$app_intents_metadata/version.json" 2>/dev/null || true
  )"
  if [[ "$metadata_version" != "3.0" || -z "$metadata_tools_version" ]]; then
    echo "Bundle verification failed: App Intents version metadata is invalid." >&2
    return 1
  fi

  local metadata_path
  for metadata_path in \
    "actions.OpenWatchedAppIntent" \
    "actions.RefreshTaskScopeIntent" \
    "actions.StopWatchedAppIntent" \
    "entities.WatchedPresetEntity" \
    "queries.WatchedPresetEntityQuery"; do
    if ! /usr/bin/plutil -extract "$metadata_path" json -o - \
      "$app_intents_metadata/extract.actionsdata" >/dev/null 2>&1; then
      echo "Bundle verification failed: App Intents metadata lacks $metadata_path." >&2
      return 1
    fi
  done

  local shortcut_metadata
  shortcut_metadata="$(
    /usr/bin/plutil -extract autoShortcuts json -o - \
      "$app_intents_metadata/extract.actionsdata"
  )"
  for phrase in \
    'Refresh ${applicationName}' \
    'Stop ${app} in ${applicationName}' \
    'Open ${app} in ${applicationName}'; do
    if ! /usr/bin/grep -Fq "$phrase" <<< "$shortcut_metadata"; then
      echo "Bundle verification failed: App Shortcut phrase '$phrase' is missing." >&2
      return 1
    fi
  done

  /usr/bin/codesign --verify --deep --strict "$bundle"
}

# The icns must carry every iconset member at its exact pixel size; a member
# rendered at the wrong scale is dropped by iconutil and Finder then shows a
# blurry or generic icon at that size.
verify_icon_members() {
  local icon="$1"
  local iconset_dir
  local member
  local expected
  local actual

  iconset_dir="$(mktemp -d "${TMPDIR:-/tmp}/taskscope-iconset.XXXXXX")"
  if ! /usr/bin/iconutil -c iconset "$icon" -o "$iconset_dir/AppIcon.iconset" 2>/dev/null; then
    echo "Bundle verification failed: iconutil could not read AppIcon.icns." >&2
    rm -rf "$iconset_dir"
    return 1
  fi
  for member in \
    icon_16x16.png icon_16x16@2x.png \
    icon_32x32.png icon_32x32@2x.png \
    icon_128x128.png icon_128x128@2x.png \
    icon_256x256.png icon_256x256@2x.png \
    icon_512x512.png icon_512x512@2x.png; do
    if [[ ! -s "$iconset_dir/AppIcon.iconset/$member" ]]; then
      echo "Bundle verification failed: AppIcon.icns lacks $member." >&2
      rm -rf "$iconset_dir"
      return 1
    fi
    expected="${member#icon_}"
    expected="${expected%%x*}"
    if [[ "$member" == *"@2x"* ]]; then
      expected=$((expected * 2))
    fi
    actual="$(/usr/bin/sips -g pixelWidth "$iconset_dir/AppIcon.iconset/$member" 2>/dev/null \
      | /usr/bin/awk '/pixelWidth/ { print $2 }')"
    if [[ "$actual" != "$expected" ]]; then
      echo "Bundle verification failed: $member is ${actual:-unknown} pixels wide (expected $expected)." >&2
      rm -rf "$iconset_dir"
      return 1
    fi
  done
  rm -rf "$iconset_dir"
}

unregister_staged_app() {
  local registrar="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

  # Startup verification registers the temporary build as a launchable app.
  # Excluding metadata alone does not remove that second Spotlight source.
  if [[ -x "$registrar" ]]; then
    "$registrar" -u "$APP_BUNDLE" >/dev/null 2>&1 || true
  fi
}

verify_startup_readiness() (
  local bundle="$1"
  local executable="$bundle/Contents/MacOS/$APP_NAME"
  local readiness_home
  local verify_pid=""
  local verify_pid_identity=""
  local verify_pid_start=""
  local script_command=""
  local attempt
  local registered_bundle_id=""
  local is_ready=0

  readiness_home="$(mktemp -d "${TMPDIR:-/tmp}/taskscope-startup.XXXXXX")"

  readiness_process_is_running() {
    local start_time

    [[ -n "$verify_pid" && -n "$verify_pid_start" ]] || return 1
    start_time="$(taskscope_process_start_time "$verify_pid")" || return 1
    [[ "$start_time" == "$verify_pid_start" ]]
  }

  signal_readiness_process() {
    local signal="$1"
    local command

    readiness_process_is_running || return 1
    # After exec the kernel text vnode must be the packaged executable. Before
    # exec the child is still this script's forked shell, which may be stopped
    # too; otherwise a slow exec would leave the app running after cleanup.
    if ! taskscope_process_matches_executable "$verify_pid" "$executable"; then
      command="$(taskscope_process_command "$verify_pid")" || return 1
      [[ -n "$script_command" && "$command" == "$script_command" ]] || return 1
    fi
    readiness_process_is_running || return 1
    taskscope_send_signal "$signal" "$verify_pid"
  }

  wait_for_readiness_process_exit() {
    for _ in {1..20}; do
      readiness_process_is_running || return 0
      /bin/sleep 0.1
    done
    ! readiness_process_is_running
  }

  cleanup_readiness_process() {
    if [[ -n "$verify_pid" ]]; then
      signal_readiness_process TERM >/dev/null 2>&1 || true
      if ! wait_for_readiness_process_exit; then
        signal_readiness_process KILL >/dev/null 2>&1 || true
        wait_for_readiness_process_exit || true
      fi
      # Only reap a child that is gone; waiting on a live one would hang.
      if readiness_process_is_running; then
        echo "Could not stop startup verification process $verify_pid." >&2
      else
        wait "$verify_pid" 2>/dev/null || true
      fi
      verify_pid=""
    fi
    rm -rf "$readiness_home"
    unregister_staged_app
  }
  trap cleanup_readiness_process EXIT

  script_command="$(taskscope_process_command "$$" || true)"
  CFFIXED_USER_HOME="$readiness_home" \
    "$executable" --automation --verify-startup >/dev/null 2>&1 &
  verify_pid="$!"
  # Captured at once: an unreaped child's PID cannot yet belong to another process.
  verify_pid_start="$(taskscope_process_start_time "$verify_pid" || true)"
  verify_pid_identity="$(
    taskscope_wait_for_process_identity "$verify_pid" 40 "$executable"
  )" || {
    echo "Bundle verification failed: could not capture startup process identity." >&2
    return 1
  }

  for attempt in {1..50}; do
    if ! taskscope_process_matches_identity "$verify_pid" "$verify_pid_identity"; then
      wait "$verify_pid" 2>/dev/null || true
      echo "Bundle verification failed: packaged app exited during startup." >&2
      return 1
    fi

    registered_bundle_id="$(
      /usr/bin/lsappinfo info -only bundleid -app "$verify_pid" 2>/dev/null || true
    )"
    if [[ "$registered_bundle_id" == *"$BUNDLE_ID"* ]]; then
      is_ready=1
      break
    fi

    /bin/sleep 0.1
  done

  if [[ "$is_ready" -ne 1 ]]; then
    echo "Bundle verification failed: app did not register with Launch Services within 5 seconds." >&2
    return 1
  fi

  cleanup_readiness_process
  trap - EXIT
)

stop_staged_app_instances() {
  taskscope_stop_processes_for_executable "$APP_BINARY"
}

cd "$ROOT_DIR"
STAGING_BUNDLE="$DIST_DIR/.$APP_NAME.staging.$$"
STAGING_CONTENTS="$STAGING_BUNDLE/Contents"
STAGING_MACOS="$STAGING_CONTENTS/MacOS"
STAGING_RESOURCES="$STAGING_CONTENTS/Resources"
STAGING_BINARY="$STAGING_MACOS/$APP_NAME"
STAGING_PLIST="$STAGING_CONTENTS/Info.plist"
STAGING_ICON="$STAGING_RESOURCES/AppIcon.icns"
METADATA_BUILD_CONFIGURATION="release"
METADATA_WORK_DIR=""
APP_INTENTS_CONST_VALUES=""
APP_INTENTS_SOURCE_LIST=""
APP_INTENTS_CONST_LIST=""
APP_INTENTS_PROTOCOLS=""
PACKAGING_LOCK="$DIST_DIR/.$APP_NAME.package.lock"
PACKAGING_LOCK_ACQUIRED=0
OUTPUT_BACKUP="$DIST_DIR/.$APP_NAME.output-backup.$$"
VERIFIED_BUNDLE_COPY="${TASKSCOPE_VERIFIED_BUNDLE_COPY:-}"
VERIFIED_COPY_TEMP=""
PUBLISH_COMPLETE=0

cleanup_packaging_work() {
  local exit_code="$?"

  if [[ -d "$STAGING_BUNDLE" ]]; then
    rm -rf "$STAGING_BUNDLE"
  fi
  if [[ -d "$OUTPUT_BACKUP" ]]; then
    if [[ "$PUBLISH_COMPLETE" -eq 1 ]]; then
      rm -rf "$OUTPUT_BACKUP"
    else
      rm -rf "$APP_BUNDLE"
      mv "$OUTPUT_BACKUP" "$APP_BUNDLE"
    fi
  fi
  if [[ -n "$METADATA_WORK_DIR" && -d "$METADATA_WORK_DIR" ]]; then
    rm -rf "$METADATA_WORK_DIR"
  fi
  if [[ -n "$VERIFIED_COPY_TEMP" && -d "$VERIFIED_COPY_TEMP" ]]; then
    rm -rf "$VERIFIED_COPY_TEMP"
  fi
  if [[ "$PACKAGING_LOCK_ACQUIRED" -eq 1 ]]; then
    rm -f "$PACKAGING_LOCK"
  fi

  return "$exit_code"
}
trap cleanup_packaging_work EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$DIST_DIR"
if ! /usr/bin/shlock -f "$PACKAGING_LOCK" -p "$$"; then
  echo "Another TaskScope packaging process owns $PACKAGING_LOCK." >&2
  exit 1
fi
PACKAGING_LOCK_ACQUIRED=1

# Hold the packaging lock across both static and startup verification so a
# concurrent restage cannot replace the bundle or stop the readiness process.
# --verify never rebuilds or restages; run --stage first for a fresh bundle.
if [[ "$MODE" == "--verify" || "$MODE" == "verify" ]]; then
  if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "Nothing to verify: $APP_BUNDLE does not exist. Run $0 --stage first." >&2
    exit 1
  fi
  verify_bundle "$APP_BUNDLE"
  verify_startup_readiness "$APP_BUNDLE"
  echo "Verified existing $APP_BUNDLE (not rebuilt)"
  exit 0
fi

rm -rf "$STAGING_BUNDLE"
rm -rf "$OUTPUT_BACKUP"
METADATA_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/taskscope-app-intents.XXXXXX")"
APP_INTENTS_CONST_VALUES="$METADATA_WORK_DIR/TaskScope.swiftconstvalues"
APP_INTENTS_SOURCE_LIST="$METADATA_WORK_DIR/app-intents-sources.txt"
APP_INTENTS_CONST_LIST="$METADATA_WORK_DIR/app-intents-const-values.txt"
APP_INTENTS_PROTOCOLS="$METADATA_WORK_DIR/app-intents-protocols.json"
mkdir -p "$METADATA_WORK_DIR"

TOOLCHAIN_DIR="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
APP_INTENTS_PROTOCOL_SOURCE="$TOOLCHAIN_DIR/usr/share/swift/SwiftConstantValues/AppIntents.json"
if [[ ! -s "$APP_INTENTS_PROTOCOL_SOURCE" ]]; then
  echo "Missing App Intents compiler protocol metadata: $APP_INTENTS_PROTOCOL_SOURCE" >&2
  exit 1
fi
/usr/bin/plutil -extract constValueProtocols json -o "$APP_INTENTS_PROTOCOLS" \
  "$APP_INTENTS_PROTOCOL_SOURCE"

# SwiftPM links with the deployment target as the binary's SDK version, which
# opts the app into old-SDK compatibility behavior. Record the real SDK.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
LINKER_PLATFORM_FLAGS=(
  -Xlinker -platform_version -Xlinker macos
  -Xlinker "$MIN_SYSTEM_VERSION" -Xlinker "$SDK_VERSION"
)

if [[ "$BUILD_CONFIGURATION" == "debug" ]]; then
  swift build -c debug --disable-index-store "${LINKER_PLATFORM_FLAGS[@]}"
fi

swift build -c "$METADATA_BUILD_CONFIGURATION" --disable-index-store \
  "${LINKER_PLATFORM_FLAGS[@]}" \
  -Xswiftc -emit-const-values \
  -Xswiftc -Xfrontend \
  -Xswiftc -const-gather-protocols-file \
  -Xswiftc -Xfrontend \
  -Xswiftc "$APP_INTENTS_PROTOCOLS" \
  -Xswiftc -emit-const-values-path \
  -Xswiftc "$APP_INTENTS_CONST_VALUES"
BUILD_BINARY="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)/$PRODUCT_NAME"

if [[ ! -s "$APP_INTENTS_CONST_VALUES" ]]; then
  echo "App Intents constant-value extraction produced no metadata." >&2
  exit 1
fi

printf '%s\n' "$ROOT_DIR/Sources/TaskScope/Services/TaskScopeIntents.swift" > "$APP_INTENTS_SOURCE_LIST"
printf '%s\n' "$APP_INTENTS_CONST_VALUES" > "$APP_INTENTS_CONST_LIST"

mkdir -p "$STAGING_MACOS" "$STAGING_RESOURCES"
cp "$BUILD_BINARY" "$STAGING_BINARY"
chmod +x "$STAGING_BINARY"

swift "$ROOT_DIR/script/render_icon.swift" "$STAGING_ICON"

/usr/libexec/PlistBuddy -c "Clear dict" "$STAGING_PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $APP_NAME" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $APP_VERSION" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $APP_BUILD_NUMBER" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $MIN_SYSTEM_VERSION" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool false" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :NSPrincipalClass string NSApplication" "$STAGING_PLIST"

/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0 dict" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLName string $BUNDLE_ID" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string taskscope" "$STAGING_PLIST"

APP_INTENTS_PROCESSOR="$(xcrun --find appintentsmetadataprocessor)"
SDK_ROOT="$(xcrun --sdk macosx --show-sdk-path)"
XCODE_BUILD_VERSION="$(xcodebuild -version | awk 'NR == 2 { print $3 }')"
TARGET_TRIPLE="$(uname -m)-apple-macos${MIN_SYSTEM_VERSION}"

"$APP_INTENTS_PROCESSOR" \
  --output "$STAGING_RESOURCES" \
  --toolchain-dir "$TOOLCHAIN_DIR" \
  --module-name "$PRODUCT_NAME" \
  --sdk-root "$SDK_ROOT" \
  --xcode-version "$XCODE_BUILD_VERSION" \
  --platform-family macOS \
  --deployment-target "$MIN_SYSTEM_VERSION" \
  --target-triple "$TARGET_TRIPLE" \
  --source-file-list "$APP_INTENTS_SOURCE_LIST" \
  --swift-const-vals-list "$APP_INTENTS_CONST_LIST" \
  --force \
  --no-app-shortcuts-localization

/usr/bin/xattr -cr "$STAGING_BUNDLE"
if [[ "$SIGNING_STYLE" == "distribution" ]]; then
  /usr/bin/codesign --force --options runtime --timestamp \
    --sign "$CODE_SIGN_IDENTITY" "$STAGING_BUNDLE"
else
  /usr/bin/codesign --force --timestamp=none \
    --sign "$CODE_SIGN_IDENTITY" "$STAGING_BUNDLE"
fi
verify_bundle "$STAGING_BUNDLE"

case "$MODE" in
  run|--stage|stage|--debug|debug|--logs|logs|--telemetry|telemetry)
    # Stop running copies before the swap: afterwards their executable is the
    # deleted backup, which the kernel-path check can no longer match, and the
    # next launch would leave two instances running.
    stop_staged_app_instances
    ;;
esac

if [[ -d "$APP_BUNDLE" ]]; then
  mv "$APP_BUNDLE" "$OUTPUT_BACKUP"
fi
if ! mv "$STAGING_BUNDLE" "$APP_BUNDLE"; then
  if [[ -d "$OUTPUT_BACKUP" ]]; then
    mv "$OUTPUT_BACKUP" "$APP_BUNDLE"
  fi
  exit 1
fi
PUBLISH_COMPLETE=1
rm -rf "$OUTPUT_BACKUP"

if [[ -n "$VERIFIED_BUNDLE_COPY" ]]; then
  case "$VERIFIED_BUNDLE_COPY" in
    /*/TaskScope.app)
      ;;
    *)
      echo "TASKSCOPE_VERIFIED_BUNDLE_COPY must be an absolute TaskScope.app path." >&2
      exit 1
      ;;
  esac
  if [[ -e "$VERIFIED_BUNDLE_COPY" ]]; then
    echo "Refusing to overwrite verified bundle copy: $VERIFIED_BUNDLE_COPY" >&2
    exit 1
  fi
  if [[ ! -d "$(dirname "$VERIFIED_BUNDLE_COPY")" ]]; then
    echo "Verified bundle copy destination directory does not exist." >&2
    exit 1
  fi

  VERIFIED_COPY_TEMP="$VERIFIED_BUNDLE_COPY.copying.$$"
  [[ ! -e "$VERIFIED_COPY_TEMP" ]] || {
    echo "Refusing to overwrite verified bundle copy staging path." >&2
    exit 1
  }
  /usr/bin/ditto "$APP_BUNDLE" "$VERIFIED_COPY_TEMP"
  verify_bundle "$VERIFIED_COPY_TEMP"
  mv "$VERIFIED_COPY_TEMP" "$VERIFIED_BUNDLE_COPY"
  VERIFIED_COPY_TEMP=""
fi

cleanup_packaging_work
trap - EXIT INT TERM

open_app() {
  taskscope_require_no_other_app_instance "$APP_BUNDLE" "$BUNDLE_ID" || return 1
  /usr/bin/open "$APP_BUNDLE"
}

case "$MODE" in
  --stage|stage)
    unregister_staged_app
    echo "$APP_BUNDLE"
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    taskscope_require_no_other_app_instance "$APP_BUNDLE" "$BUNDLE_ID"
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
esac
