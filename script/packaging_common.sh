#!/usr/bin/env bash

# Shared, side-effect-free validation used by the local and release packaging
# entry points. Callers intentionally retain their own `set` options.

TASKSCOPE_DEVELOPMENT_BUNDLE_ID="com.local.TaskScope"

taskscope_validate_bundle_id() {
  local bundle_id="$1"

  if [[ ${#bundle_id} -gt 255 \
    || ! "$bundle_id" =~ ^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z][A-Za-z0-9-]*)+$ ]]; then
    echo "Invalid TaskScope bundle identifier: '$bundle_id'." >&2
    echo "Use a reverse-DNS identifier containing letters, numbers, and hyphens." >&2
    return 1
  fi
}

taskscope_resolve_bundle_id() {
  local bundle_id="${TASKSCOPE_BUNDLE_ID:-$TASKSCOPE_DEVELOPMENT_BUNDLE_ID}"

  taskscope_validate_bundle_id "$bundle_id" || return 1
  printf '%s' "$bundle_id"
}

taskscope_read_release_value() {
  local path="$1"
  local label="$2"
  local value

  if [[ ! -f "$path" ]]; then
    echo "Missing $label source: $path" >&2
    return 1
  fi

  value="$(tr -d '[:space:]' < "$path")"
  if [[ -z "$value" ]]; then
    echo "$label source is empty: $path" >&2
    return 1
  fi

  printf '%s' "$value"
}

taskscope_validate_build_number_history() {
  local root_dir="$1"
  local build_number="$2"
  local tags
  local tag
  local tagged_build
  local maximum_build=0
  local maximum_tag=""
  local release_tag_count=0
  local LC_ALL=C

  tags="$(git -C "$root_dir" tag --list 'v*')" || {
    echo "Could not list release tags." >&2
    return 1
  }
  while IFS= read -r tag; do
    # Only v<major>.<minor>[.<patch>][-<suffix>] names are release tags.
    [[ "$tag" =~ ^v[0-9]+(\.[0-9]+){1,2}(-[A-Za-z0-9.-]+)?$ ]] || continue
    release_tag_count=$((release_tag_count + 1))
    tagged_build="$(git -C "$root_dir" show "$tag:BUILD_NUMBER" 2>/dev/null)" || {
      echo "Could not read BUILD_NUMBER at $tag." >&2
      return 1
    }
    tagged_build="$(printf '%s' "$tagged_build" | tr -d '[:space:]')"
    if [[ ! "$tagged_build" =~ ^[1-9][0-9]*$ ]]; then
      echo "Invalid BUILD_NUMBER at $tag: '$tagged_build'." >&2
      return 1
    fi
    # Compare decimal strings without overflowing shell integer arithmetic.
    if [[ ${#tagged_build} -gt ${#maximum_build} \
      || ( ${#tagged_build} -eq ${#maximum_build} && "$tagged_build" > "$maximum_build" ) ]]; then
      maximum_build="$tagged_build"
      maximum_tag="$tag"
    fi
  done <<< "$tags"

  # Missing tags would make any build number pass, as in a --no-tags clone.
  if [[ "$release_tag_count" -eq 0 && "${TASKSCOPE_FIRST_RELEASE:-0}" != 1 ]]; then
    echo "No local release tags. Fetch the release tags, or set TASKSCOPE_FIRST_RELEASE=1 for the first release." >&2
    return 1
  fi
  if [[ ${#build_number} -lt ${#maximum_build} \
    || ( ${#build_number} -eq ${#maximum_build} && ! "$build_number" > "$maximum_build" ) ]]; then
    echo "BUILD_NUMBER ($build_number) must be greater than the value at $maximum_tag ($maximum_build)." >&2
    return 1
  fi
}

taskscope_find_signing_identity() {
  local requested="$1"

  # Prints "<SHA-1> <name>" for the first valid identity whose SHA-1 or exact
  # name is requested. Signing by SHA-1 avoids codesign's "ambiguous" error
  # when several valid certificates share a name, e.g. after a renewal.
  /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/awk -F '"' -v requested="$requested" '
        {
          split($1, fields, " ")
          hash = fields[2]
          if (length(hash) == 40 && (hash == toupper(requested) || $2 == requested)) {
            print hash " " $2
            found = 1
            exit
          }
        }
        END { exit found ? 0 : 1 }'
}

taskscope_running_bundle_paths() {
  # Read Launch Services through AppKit so paths containing spaces need no
  # parsing of lsappinfo's display format. This lookup never stops an app.
  /usr/bin/swift - "$1" <<'SWIFT'
import AppKit

let identifier = CommandLine.arguments[1]
for application in NSWorkspace.shared.runningApplications
    where application.bundleIdentifier == identifier && !application.isTerminated {
    guard let url = application.bundleURL else {
        fputs("Could not resolve a running application's bundle path.\n", stderr)
        exit(1)
    }
    print("\(application.processIdentifier)\t\(url.resolvingSymlinksInPath().standardizedFileURL.path)")
}
SWIFT
}

taskscope_process_runs_bundle_executable() {
  local pid="$1"
  local bundle="$2"
  local executable_name
  local expected_identity
  local device
  local inode

  # Launch Services keeps the bundle URL an app was launched from, so a copy
  # started before its bundle was deleted and rebuilt still reports this path.
  # Compare the kernel text vnode's device and inode with the bundle's current
  # executable; the name lsof reports for an unlinked file is not reliable.
  executable_name="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
      "$bundle/Contents/Info.plist" 2>/dev/null
  )" || return 1
  [[ -n "$executable_name" ]] || return 1
  expected_identity="$(
    /usr/bin/stat -f '%d %i' "$bundle/Contents/MacOS/$executable_name" 2>/dev/null
  )" || return 1
  read -r device inode < <(
    LC_ALL=en_US.UTF-8 /usr/sbin/lsof -a -p "$pid" -d txt -FDi 2>/dev/null \
      | /usr/bin/awk '
          substr($0, 1, 1) == "D" && device == "" { device = substr($0, 2) }
          substr($0, 1, 1) == "i" { print device, substr($0, 2); exit }'
  ) || return 1
  [[ "$device" =~ ^0x[0-9A-Fa-f]+$ && "$inode" =~ ^[0-9]+$ ]] || return 1
  [[ "$((16#${device#0x})) $inode" == "$expected_identity" ]]
}

taskscope_require_no_other_app_instance() {
  local bundle="$1"
  local bundle_id="$2"
  local expected_path
  local running_paths
  local pid
  local path

  expected_path="$bundle"
  if [[ -d "$bundle" ]]; then
    expected_path="$(cd "$bundle" && pwd -P)" || return 1
  fi
  running_paths="$(taskscope_running_bundle_paths "$bundle_id")" || {
    echo "Could not check running TaskScope applications; refusing to launch $bundle." >&2
    return 1
  }
  while IFS=$'\t' read -r pid path; do
    [[ -n "$pid" || -n "$path" ]] || continue
    # Foundation's symlink resolution drops a leading /private (for example
    # /private/var becomes /var), so compare the physical directory paths.
    if [[ "$path" == "$expected_path" \
      || ( -d "$path" && "$(cd "$path" && pwd -P)" == "$expected_path" ) ]]; then
      # `open` would only activate a same-path copy, so it must be running the
      # bundle's current executable rather than a build that was replaced.
      if [[ "$pid" =~ ^[0-9]+$ ]] \
        && taskscope_process_runs_bundle_executable "$pid" "$bundle"; then
        continue
      fi
      echo "TaskScope process $pid is running an older build of $bundle." >&2
      echo "Quit that copy before launching $bundle." >&2
      return 1
    fi
    echo "TaskScope with bundle identifier '$bundle_id' is already running at $path." >&2
    echo "Quit that copy before launching $bundle." >&2
    return 1
  done <<< "$running_paths"
}

taskscope_process_command() {
  local pid="$1"
  local command

  command="$(LC_ALL=en_US.UTF-8 /bin/ps -ww -p "$pid" -o command= 2>/dev/null)" || return 1
  [[ -n "$command" ]] || return 1
  printf '%s' "$command"
}

taskscope_process_identity() {
  local pid="$1"
  local identity

  # PID alone is unsafe because macOS can reuse it after a process exits. The
  # process start time and full command together provide a stable shell-level
  # identity that can be revalidated immediately before each signal.
  identity="$(LC_ALL=en_US.UTF-8 /bin/ps -ww -p "$pid" -o lstart= -o command= 2>/dev/null)" || return 1
  [[ -n "$identity" ]] || return 1
  printf '%s' "$identity"
}

taskscope_process_start_time() {
  local pid="$1"
  local state
  local start_time

  # The start time survives exec, so PID plus start time follows a forked
  # child from the shell into the program it runs. Exited zombies do not count.
  read -r state start_time < <(LC_ALL=en_US.UTF-8 /bin/ps -p "$pid" -o stat= -o lstart= 2>/dev/null) \
    || return 1
  [[ -n "$start_time" && "$state" != Z* ]] || return 1
  printf '%s' "$start_time"
}

taskscope_wait_for_process_identity() {
  local pid="$1"
  local attempts="${2:-20}"
  local expected_executable="${3:-}"
  local identity
  local command
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    # Right after `&` the child can still be the forked shell; when the caller
    # names the executable, wait for the exec so the identity is the program's.
    if [[ -n "$expected_executable" ]]; then
      command="$(taskscope_process_command "$pid")" || command=""
      if [[ "$command" != "$expected_executable" \
        && "$command" != "$expected_executable "* ]]; then
        /bin/sleep 0.05
        continue
      fi
    fi
    if identity="$(taskscope_process_identity "$pid")"; then
      printf '%s' "$identity"
      return 0
    fi
    /bin/sleep 0.05
  done

  return 1
}

taskscope_process_matches_identity() {
  local pid="$1"
  local expected_identity="$2"
  local current_identity

  current_identity="$(taskscope_process_identity "$pid")" || return 1
  [[ "$current_identity" == "$expected_identity" ]]
}

taskscope_canonical_file_path() {
  local path="$1"
  local directory

  [[ -e "$path" ]] || return 1
  directory="$(cd "$(dirname "$path")" && pwd -P)" || return 1
  printf '%s/%s' "$directory" "$(basename "$path")"
}

taskscope_process_executable_path() {
  local pid="$1"
  local executable

  # `lsof` obtains the process text vnode from the kernel. Unlike `ps`
  # command/argv0, an untrusted process cannot forge this path with `exec -a`.
  executable="$(
    LC_ALL=en_US.UTF-8 /usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null \
      | /usr/bin/awk 'substr($0, 1, 1) == "n" { print substr($0, 2); exit }'
  )"
  [[ -n "$executable" ]] || return 1
  printf '%s' "$executable"
}

taskscope_process_matches_executable() {
  local pid="$1"
  local expected_executable="$2"
  local expected_canonical
  local actual_executable
  local actual_canonical

  expected_canonical="$(taskscope_canonical_file_path "$expected_executable")" || return 1
  actual_executable="$(taskscope_process_executable_path "$pid")" || return 1
  actual_canonical="$(taskscope_canonical_file_path "$actual_executable")" || return 1
  [[ "$actual_canonical" == "$expected_canonical" ]]
}

taskscope_send_signal() {
  local signal="$1"
  local pid="$2"

  /bin/kill "-$signal" "$pid"
}

taskscope_list_processes() {
  LC_ALL=en_US.UTF-8 /bin/ps -ww -axo pid=,command=
}

taskscope_pause() {
  /bin/sleep "$1"
}

taskscope_signal_process_if_identity_matches() {
  local signal="$1"
  local pid="$2"
  local expected_identity="$3"
  local expected_executable="$4"

  case "$signal" in
    TERM|KILL)
      ;;
    *)
      echo "Unsupported TaskScope packaging signal: $signal" >&2
      return 2
      ;;
  esac

  taskscope_process_matches_identity "$pid" "$expected_identity" || return 1
  taskscope_process_matches_executable "$pid" "$expected_executable" || return 1
  taskscope_send_signal "$signal" "$pid"
}

taskscope_stop_processes_for_executable() {
  local executable="$1"
  local canonical_executable
  local pid
  local command
  local identity
  local current_command
  local index
  local -a matching_pids=()
  local -a matching_identities=()

  # Callers read this after a successful call: 1 only when verified processes
  # were found and every one of them stopped, so a caller can report it.
  TASKSCOPE_STOPPED_PROCESSES=0
  [[ -x "$executable" ]] || return 0
  canonical_executable="$(taskscope_canonical_file_path "$executable")" || return 0

  while read -r pid command; do
    if [[ "$command" == "$executable" || "$command" == "$executable "* \
      || "$command" == "$canonical_executable" || "$command" == "$canonical_executable "* ]]; then
      identity="$(taskscope_process_identity "$pid")" || continue
      current_command="$(taskscope_process_command "$pid")" || continue
      if [[ "$current_command" == "$executable" || "$current_command" == "$executable "* \
        || "$current_command" == "$canonical_executable" \
        || "$current_command" == "$canonical_executable "* ]] \
        && taskscope_process_matches_identity "$pid" "$identity" \
        && taskscope_process_matches_executable "$pid" "$canonical_executable"; then
        matching_pids+=("$pid")
        matching_identities+=("$identity")
      fi
    fi
  done < <(taskscope_list_processes)

  if [[ "${#matching_pids[@]}" -eq 0 ]]; then
    return 0
  fi

  for ((index = 0; index < ${#matching_pids[@]}; index++)); do
    taskscope_signal_process_if_identity_matches \
      TERM "${matching_pids[$index]}" "${matching_identities[$index]}" \
      "$canonical_executable" >/dev/null 2>&1 || true
  done

  for _ in {1..20}; do
    local any_running=0
    for ((index = 0; index < ${#matching_pids[@]}; index++)); do
      if taskscope_process_matches_identity \
        "${matching_pids[$index]}" "${matching_identities[$index]}"; then
        any_running=1
        break
      fi
    done
    if [[ "$any_running" -eq 0 ]]; then
      TASKSCOPE_STOPPED_PROCESSES=1
      return 0
    fi
    taskscope_pause 0.1
  done

  for ((index = 0; index < ${#matching_pids[@]}; index++)); do
    taskscope_signal_process_if_identity_matches \
      KILL "${matching_pids[$index]}" "${matching_identities[$index]}" \
      "$canonical_executable" >/dev/null 2>&1 || true
  done

  for _ in {1..20}; do
    local any_running=0
    for ((index = 0; index < ${#matching_pids[@]}; index++)); do
      if taskscope_process_matches_identity \
        "${matching_pids[$index]}" "${matching_identities[$index]}"; then
        any_running=1
        break
      fi
    done
    if [[ "$any_running" -eq 0 ]]; then
      TASKSCOPE_STOPPED_PROCESSES=1
      return 0
    fi
    taskscope_pause 0.1
  done

  echo "Could not stop every verified TaskScope process for $canonical_executable." >&2
  return 1
}

# Prevent inherited Git repository overrides from redirecting -C operations.
taskscope_clear_git_environment() {
  local name
  while IFS= read -r name; do
    unset "$name"
  done < <(git rev-parse --local-env-vars)
}

taskscope_validate_copy_destination() {
  local destination="$1"
  [[ -n "$destination" ]] || return 0
  case "$destination" in
    /*/TaskScope.app) ;;
    *) echo "TASKSCOPE_VERIFIED_BUNDLE_COPY must be an absolute TaskScope.app path." >&2; return 1 ;;
  esac
  if [[ -e "$destination" || -L "$destination" ]]; then
    echo "Refusing to overwrite verified bundle copy: $destination" >&2
    return 1
  fi
  if [[ ! -d "$(dirname "$destination")" ]]; then
    echo "Verified bundle copy destination directory does not exist." >&2
    return 1
  fi
}

taskscope_require_xcode() {
  local version
  local major
  version="$(xcodebuild -version 2>/dev/null)" || version="unavailable"
  major="$(awk '/^Xcode / { split($2, v, "."); print v[1]; exit }' <<< "$version")"
  if [[ ! "$major" =~ ^[0-9]+$ || "$major" -lt 26 ]]; then
    echo "TaskScope packaging needs Xcode 26 or later selected with xcode-select (found: $version)." >&2
    return 2
  fi
}

# Prints the package description as JSON. dump-package only evaluates the
# manifest; it never resolves or fetches dependencies.
taskscope_describe_package() {
  swift package --package-path "$1" dump-package
}

taskscope_minimum_system_version() {
  taskscope_describe_package "$1" | /usr/bin/plutil -extract platforms.0.version raw -o - -
}

# Package.swift alone sets the deployment target, so the linker's minimum OS,
# LSMinimumSystemVersion and the App Intents metadata always match the code.
# Every packaging script reads it through this function.
taskscope_resolve_minimum_system_version() {
  local version

  version="$(taskscope_minimum_system_version "$1" 2>/dev/null)" || version=""
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Could not determine the Package.swift macOS deployment target." >&2
    return 1
  fi
  printf '%s' "$version"
}

# script/expected_intents.json is the one list of the App Intents types and App
# Shortcut phrases a packaged TaskScope declares. The app embeds the same file
# (script/generate_expected_intents.sh) for its Settings > Health check.
taskscope_expected_intents_file() {
  printf '%s/script/expected_intents.json' "$1"
}

# Prints the strings of the array at KEYPATH in a JSON or property list file,
# one per line. Fails unless the value is an array of non-empty one-line strings.
taskscope_string_list() {
  local file="$1"
  local keypath="$2"
  local count
  local index
  local value

  count="$(/usr/bin/plutil -extract "$keypath" raw -expect array -o - "$file" 2>/dev/null)" || return 1
  [[ "$count" =~ ^[0-9]+$ ]] || return 1
  for ((index = 0; index < count; index++)); do
    value="$(/usr/bin/plutil -extract "$keypath.$index" raw -expect string -o - "$file" 2>/dev/null)" \
      || return 1
    [[ -n "$value" && "$value" != *$'\n'* ]] || return 1
    printf '%s\n' "$value"
  done
}

# Prints the differences between two newline-separated lists as "-name" for a
# name only the first has and "+name" for one only the second has.
taskscope_list_differences() {
  local LC_ALL=C

  /usr/bin/comm -23 <(printf '%s\n' "$1" | /usr/bin/sed '/^$/d' | /usr/bin/sort -u) \
    <(printf '%s\n' "$2" | /usr/bin/sed '/^$/d' | /usr/bin/sort -u) | /usr/bin/sed 's/^/-/'
  /usr/bin/comm -13 <(printf '%s\n' "$1" | /usr/bin/sed '/^$/d' | /usr/bin/sort -u) \
    <(printf '%s\n' "$2" | /usr/bin/sed '/^$/d' | /usr/bin/sort -u) | /usr/bin/sed 's/^/+/'
}

# Prints the names a metadata group declares, one per line: the keys of a
# dictionary group (actions, entities, queries) or the identifier of each entry
# of an array group (enums). A missing group declares nothing; an array entry
# without an identifier fails.
taskscope_metadata_names() {
  local file="$1"
  local group="$2"
  local type
  local count
  local index

  type="$(/usr/bin/plutil -type "$group" "$file" 2>/dev/null)" || return 0
  case "$type" in
    dictionary)
      # A dictionary prints one key per line in raw format.
      /usr/bin/plutil -extract "$group" raw -o - "$file" 2>/dev/null
      ;;
    array)
      count="$(/usr/bin/plutil -extract "$group" raw -o - "$file" 2>/dev/null)" || return 1
      [[ "$count" =~ ^[0-9]+$ ]] || return 1
      for ((index = 0; index < count; index++)); do
        /usr/bin/plutil -extract "$group.$index.identifier" raw -expect string -o - "$file" 2>/dev/null \
          || return 1
      done
      ;;
    *)
      return 1
      ;;
  esac
}

# Checks a Metadata.appintents folder against the expectations file: the
# metadata format version, exactly the listed actions, entities, queries and
# enums, and exactly the listed App Shortcuts, each with exactly its phrases.
taskscope_verify_app_intents_metadata() {
  local metadata="$1"
  local expected="$2"
  local version_file="$metadata/version.json"
  local actions_file="$metadata/extract.actionsdata"
  local expected_version
  local actual_version
  local tools_version
  local group
  local wanted
  local found
  local difference
  local status=0
  local shortcut_count
  local declared_count
  local index
  local entry
  local action
  local matched
  local phrase_count
  local phrase_index

  expected_version="$(/usr/bin/plutil -extract metadataVersion raw -expect string -o - "$expected" 2>/dev/null)" \
    && shortcut_count="$(/usr/bin/plutil -extract shortcuts raw -expect array -o - "$expected" 2>/dev/null)" \
    && [[ -n "$expected_version" && "$shortcut_count" =~ ^[0-9]+$ ]] || {
    echo "Bundle verification failed: $expected is missing or malformed." >&2
    return 1
  }
  [[ -s "$version_file" ]] || {
    echo "Bundle verification failed: App Intents version metadata is missing." >&2
    return 1
  }
  [[ -s "$actions_file" ]] || {
    echo "Bundle verification failed: App Intents action metadata is missing." >&2
    return 1
  }
  actual_version="$(/usr/bin/plutil -extract version raw -o - "$version_file" 2>/dev/null || true)"
  tools_version="$(/usr/bin/plutil -extract toolsVersion raw -o - "$version_file" 2>/dev/null || true)"
  if [[ "$actual_version" != "$expected_version" || -z "$tools_version" ]]; then
    echo "Bundle verification failed: App Intents version metadata is invalid." >&2
    return 1
  fi

  for group in actions entities queries enums; do
    wanted="$(taskscope_string_list "$expected" "$group")" || {
      echo "Bundle verification failed: $expected lists no valid $group." >&2
      return 1
    }
    found="$(taskscope_metadata_names "$actions_file" "$group")" || {
      echo "Bundle verification failed: App Intents metadata has a malformed $group entry." >&2
      return 1
    }
    while IFS= read -r difference; do
      case "$difference" in
        -*) echo "Bundle verification failed: App Intents metadata lacks $group.${difference#-}." >&2 ;;
        +*) echo "Bundle verification failed: App Intents metadata declares $group.${difference#+}, which $expected does not list." >&2 ;;
        *) continue ;;
      esac
      status=1
    done < <(taskscope_list_differences "$wanted" "$found")
  done
  [[ "$status" -eq 0 ]] || return 1

  declared_count="$(/usr/bin/plutil -extract autoShortcuts raw -expect array -o - "$actions_file" 2>/dev/null || true)"
  [[ "$declared_count" =~ ^[0-9]+$ ]] || {
    echo "Bundle verification failed: App Shortcut metadata is missing." >&2
    return 1
  }
  for ((index = 0; index < shortcut_count; index++)); do
    action="$(/usr/bin/plutil -extract "shortcuts.$index.action" raw -expect string -o - "$expected" 2>/dev/null)" \
      && wanted="$(taskscope_string_list "$expected" "shortcuts.$index.phrases")" && [[ -n "$wanted" ]] || {
      echo "Bundle verification failed: $expected has a malformed shortcut at index $index." >&2
      return 1
    }
    matched=0
    for ((entry = 0; entry < declared_count; entry++)); do
      [[ "$(/usr/bin/plutil -extract "autoShortcuts.$entry.actionIdentifier" raw -o - "$actions_file" 2>/dev/null)" \
        == "$action" ]] || continue
      matched=1
      found=""
      phrase_count="$(/usr/bin/plutil -extract "autoShortcuts.$entry.phraseTemplates" raw -expect array -o - \
        "$actions_file" 2>/dev/null || true)"
      [[ "$phrase_count" =~ ^[0-9]+$ ]] || phrase_count=0
      for ((phrase_index = 0; phrase_index < phrase_count; phrase_index++)); do
        found+="$(/usr/bin/plutil -extract "autoShortcuts.$entry.phraseTemplates.$phrase_index.key" raw -o - \
          "$actions_file" 2>/dev/null || true)"$'\n'
      done
      while IFS= read -r difference; do
        case "$difference" in
          -*) echo "Bundle verification failed: App Shortcut phrase '${difference#-}' is missing." >&2 ;;
          +*) echo "Bundle verification failed: App Shortcut phrase '${difference#+}' for $action is not listed in $expected." >&2 ;;
          *) continue ;;
        esac
        status=1
      done < <(taskscope_list_differences "$wanted" "$found")
      break
    done
    if [[ "$matched" -eq 0 ]]; then
      echo "Bundle verification failed: App Intents metadata has no App Shortcut for $action." >&2
      status=1
    fi
  done
  if [[ "$status" -eq 0 && "$declared_count" -ne "$shortcut_count" ]]; then
    echo "Bundle verification failed: App Intents metadata declares $declared_count App Shortcuts; $expected lists $shortcut_count." >&2
    status=1
  fi
  return "$status"
}

taskscope_verify_plist_value() {
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

# Verifies the Info.plist and App Intents metadata of a packaged TaskScope
# against this checkout. Staging, installing and releasing all call it, so
# their checks cannot drift apart.
#   taskscope_verify_bundle_metadata LEVEL BUNDLE ROOT BUNDLE_ID VERSION BUILD [MINIMUM_SYSTEM_VERSION]
# LEVEL is one of:
#   identity  a well-formed Info.plist with the executable name, bundle
#             identifier, version and build number: enough for a copy whose
#             signature verifies, of a bundle that passed the full check.
#   full      identity, plus every other Info.plist value
#             packaging writes, no obsolete privacy keys, and App Intents
#             metadata that matches script/expected_intents.json exactly.
#             MINIMUM_SYSTEM_VERSION is required.
taskscope_verify_bundle_metadata() {
  local level="$1"
  local bundle="$2"
  local root="$3"
  local bundle_id="$4"
  local version="$5"
  local build="$6"
  local minimum="${7:-}"
  local plist="$bundle/Contents/Info.plist"
  local copyright
  local entry
  local obsolete_privacy_key

  case "$level" in
    identity) ;;
    full)
      [[ -n "$minimum" ]] || {
        echo "The full bundle metadata check needs the minimum system version." >&2
        return 2
      }
      ;;
    *)
      echo "Unknown bundle metadata level: $level" >&2
      return 2
      ;;
  esac
  [[ -d "$bundle" ]] || {
    echo "Bundle verification failed: missing $bundle" >&2
    return 1
  }
  [[ -f "$plist" ]] || {
    echo "Bundle verification failed: missing $plist" >&2
    return 1
  }
  /usr/bin/plutil -lint "$plist" >/dev/null 2>&1 || {
    echo "Bundle verification failed: $plist is not a valid property list." >&2
    return 1
  }
  taskscope_verify_plist_value "$plist" CFBundleExecutable TaskScope || return 1
  taskscope_verify_plist_value "$plist" CFBundleIdentifier "$bundle_id" || return 1
  taskscope_verify_plist_value "$plist" CFBundleShortVersionString "$version" || return 1
  taskscope_verify_plist_value "$plist" CFBundleVersion "$build" || return 1
  [[ "$level" == full ]] || return 0

  copyright="$(taskscope_copyright_notice "$root")" || return 1
  for entry in \
    CFBundleName=TaskScope \
    CFBundleDisplayName=TaskScope \
    CFBundleIconFile=AppIcon \
    CFBundlePackageType=APPL \
    "LSMinimumSystemVersion=$minimum" \
    LSUIElement=false \
    NSPrincipalClass=NSApplication \
    CFBundleInfoDictionaryVersion=6.0 \
    CFBundleDevelopmentRegion=en \
    LSApplicationCategoryType=public.app-category.utilities \
    "NSHumanReadableCopyright=$copyright" \
    "CFBundleURLTypes:0:CFBundleURLName=$bundle_id" \
    CFBundleURLTypes:0:CFBundleURLSchemes:0=taskscope; do
    taskscope_verify_plist_value "$plist" "${entry%%=*}" "${entry#*=}" || return 1
  done
  for obsolete_privacy_key in NSAppleEventsUsageDescription NSServerUsageDescription; do
    if /usr/libexec/PlistBuddy -c "Print :$obsolete_privacy_key" "$plist" >/dev/null 2>&1; then
      echo "Bundle verification failed: obsolete $obsolete_privacy_key is present." >&2
      return 1
    fi
  done
  taskscope_verify_app_intents_metadata "$bundle/Contents/Resources/Metadata.appintents" \
    "$(taskscope_expected_intents_file "$root")"
}

# Prints one target's description as JSON. Equal descriptions print the same
# text; a property list format cannot hold the nulls SwiftPM writes.
taskscope_target_description() {
  local package_path="$1"
  local target="$2"
  local description
  local name
  local index=0

  description="$(taskscope_describe_package "$package_path")" || return 1
  while name="$(/usr/bin/plutil -extract "targets.$index.name" raw -o - - <<< "$description" 2>/dev/null)"; do
    if [[ "$name" == "$target" ]]; then
      /usr/bin/plutil -extract "targets.$index" json -o - - <<< "$description"
      return
    fi
    index=$((index + 1))
  done
  echo "The package at $package_path has no $target target." >&2
  return 1
}

# The Info.plist copyright notice repeats the license's copyright line.
taskscope_copyright_notice() {
  local notice

  notice="$(/usr/bin/awk '/^Copyright \(c\) [0-9][0-9][0-9][0-9] / { print; exit }' "$1/LICENSE" 2>/dev/null)"
  if [[ -z "$notice" ]]; then
    echo "LICENSE lacks a 'Copyright (c) <year> <holder>' line." >&2
    return 1
  fi
  printf '%s' "$notice"
}

# shlock supplies atomic exclusion; the sidecar distinguishes a recycled PID
# from the process that acquired the lock. Legacy locks get an actionable error.
taskscope_acquire_lock() {
  local lock="$1"
  local description="$2"
  local pid
  local recorded_pid
  local recorded_identity
  local identity
  if ! /usr/bin/shlock -f "$lock" -p "$$"; then
    pid="$(cat "$lock" 2>/dev/null || true)"
    recorded_pid="$(head -n 1 "$lock.owner" 2>/dev/null || true)"
    recorded_identity="$(tail -n +2 "$lock.owner" 2>/dev/null || true)"
    identity="$(taskscope_process_identity "$pid" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ && "$pid" == "$recorded_pid" \
      && -n "$recorded_identity" && "$identity" != "$recorded_identity" \
      && "$(cat "$lock" 2>/dev/null)" == "$pid" ]]; then
      rm -f "$lock" "$lock.owner"
      /usr/bin/shlock -f "$lock" -p "$$" || {
        echo "Another TaskScope $description took $lock while a stale lock was removed." >&2
        return 1
      }
    else
      echo "Another TaskScope $description owns $lock. Recorded PID: $pid; current process: ${identity:-unavailable}." >&2
      echo "If this is not a TaskScope script, remove $lock and $lock.owner, then retry." >&2
      return 1
    fi
  fi
  identity="$(taskscope_process_identity "$$")" || {
    taskscope_release_lock "$lock"
    echo "Could not capture lock owner identity for $lock." >&2
    return 1
  }
  printf '%s\n%s\n' "$$" "$identity" > "$lock.owner"
}

taskscope_release_lock() {
  rm -f "$1.owner" "$1"
}

# Invoked only under the destination's transaction lock. Do not discard a
# backup when the replacement is absent or cannot be validated.
taskscope_recover_bundles() {
  local destination="$1"
  local backup_prefix="$2"
  local temporary_prefix="$3"
  local path
  local backup=""
  for path in "$backup_prefix"*; do
    [[ -e "$path" || -L "$path" ]] || continue
    [[ -d "$path" && ! -L "$path" ]] || {
      echo "Unexpected recovery artifact: $path; inspect it before retrying." >&2; return 1;
    }
    if [[ ! -e "$destination" && ! -L "$destination" ]]; then
      if [[ -n "$backup" ]]; then
        echo "Multiple backups found; restore the intended bundle to $destination before retrying." >&2
        return 1
      fi
      backup="$path"
    fi
  done
  if [[ -n "$backup" ]]; then
    mv "$backup" "$destination"
    echo "Recovered previous bundle at $destination." >&2
  fi
  for path in "$backup_prefix"* "$temporary_prefix"*; do
    [[ -e "$path" || -L "$path" ]] || continue
    [[ -d "$path" && ! -L "$path" ]] || {
      echo "Unexpected recovery artifact: $path; inspect it before retrying." >&2; return 1;
    }
    if [[ "$path" == "$backup_prefix"* ]] \
      && ! /usr/bin/codesign --verify --deep --strict "$destination" >/dev/null 2>&1; then
      echo "An interrupted run left the backup $path, and $destination fails signature verification." >&2
      echo "Keep the bundle you want at $destination, remove the other one, then retry." >&2
      return 1
    fi
    rm -rf "$path"
  done
}

taskscope_binary_rpaths() {
  /usr/bin/otool -l "$1" | /usr/bin/awk '
    $1 == "cmd" { rpath = ($2 == "LC_RPATH") }
    rpath && $1 == "path" { sub(/^[[:space:]]*path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print; rpath = 0 }'
}

taskscope_remove_build_rpaths() {
  local executable="$1"
  local paths
  local path
  paths="$(taskscope_binary_rpaths "$executable")" || return 1
  while IFS= read -r path; do
    [[ -n "$path" && "$path" != /usr/lib/swift ]] || continue
    /usr/bin/install_name_tool -delete_rpath "$path" "$executable" || return 1
  done <<< "$paths"
}

taskscope_verify_binary_paths() {
  local executable="$1"
  local paths
  local dependencies
  local path
  dependencies="$(/usr/bin/otool -L "$executable")" || return 1
  if /usr/bin/grep -Eq '^[[:space:]]+@rpath/' <<< "$dependencies"; then
    echo "Bundle verification failed: unresolved @rpath dependency." >&2
    return 1
  fi
  paths="$(taskscope_binary_rpaths "$executable")" || return 1
  while IFS= read -r path; do
    [[ -z "$path" || "$path" == /usr/lib/swift ]] || {
      echo "Bundle verification failed: non-system runtime search path: $path" >&2
      return 1
    }
  done <<< "$paths"
}

taskscope_verify_no_debug_paths() {
  local symbols
  symbols="$(/usr/bin/nm -ap "$1" 2>/dev/null)" || return 1
  if /usr/bin/grep -Eq '[[:space:]]OSO[[:space:]]' <<< "$symbols"; then
    echo "Release verification failed: debug OSO source paths remain in executable." >&2
    return 1
  fi
}

# SwiftPM resolves a root package's whole dependency graph before it builds any
# product, so building the app from Package.swift fetches the test-only
# ViewInspector package. Packaging builds this generated package instead: the
# same Sources and the same TaskScope target with no dependencies, so it never
# fetches anything and never rewrites the root Package.resolved.
taskscope_prepare_application_package() {
  local root="$1"
  local minimum_version="$2"
  local package_dir="$root/.build/taskscope-application"
  local manifest_draft="$package_dir/Package.swift.$$"
  local expected_target
  local generated_target

  mkdir -p "$package_dir" || return 1
  if [[ -L "$package_dir/Sources" ]]; then
    # A moved checkout leaves a link to its old location; the link is ours.
    if [[ "$(readlink "$package_dir/Sources")" != "$root/Sources" ]]; then
      rm "$package_dir/Sources" || return 1
    fi
  elif [[ -e "$package_dir/Sources" ]]; then
    echo "Refusing to replace app package sources: $package_dir/Sources" >&2
    return 1
  fi
  if [[ ! -L "$package_dir/Sources" ]]; then
    # A concurrent run may create the same link first.
    ln -s "$root/Sources" "$package_dir/Sources" 2>/dev/null || true
  fi
  [[ "$(readlink "$package_dir/Sources")" == "$root/Sources" ]] || {
    echo "Could not link the app package sources at $package_dir/Sources." >&2
    return 1
  }
  cat > "$manifest_draft" <<MANIFEST || return 1
// swift-tools-version: 5.9
// Generated by script/packaging_common.sh; do not edit.
import PackageDescription

let package = Package(
    name: "TaskScopeApplication",
    platforms: [.macOS("$minimum_version")],
    products: [.executable(name: "TaskScope", targets: ["TaskScope"])],
    targets: [
        .executableTarget(
            name: "TaskScope",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        )
    ]
)
MANIFEST
  # Rewrite only on change: an unchanged manifest keeps the build up to date.
  if cmp -s "$manifest_draft" "$package_dir/Package.swift"; then
    rm "$manifest_draft"
  else
    mv "$manifest_draft" "$package_dir/Package.swift" || return 1
  fi
  # Package.swift stays the single source of the app target: refuse to build a
  # target that differs from it in any setting.
  expected_target="$(taskscope_target_description "$root" TaskScope)" || return 1
  generated_target="$(taskscope_target_description "$package_dir" TaskScope)" || return 1
  if [[ "$expected_target" != "$generated_target" ]]; then
    echo "Package.swift declares the TaskScope target differently from the generated app package." >&2
    echo "Update taskscope_prepare_application_package in script/packaging_common.sh to match." >&2
    return 1
  fi
  printf '%s' "$package_dir"
}
