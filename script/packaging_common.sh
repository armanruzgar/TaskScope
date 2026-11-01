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
  local LC_ALL=C

  tags="$(git -C "$root_dir" tag --list 'v*')" || {
    echo "Could not list release tags." >&2
    return 1
  }
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
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
    /usr/sbin/lsof -a -p "$pid" -d txt -FDi 2>/dev/null \
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

  expected_path="$(cd "$bundle" && pwd -P)" || return 1
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

  command="$(/bin/ps -ww -p "$pid" -o command= 2>/dev/null)" || return 1
  [[ -n "$command" ]] || return 1
  printf '%s' "$command"
}

taskscope_process_identity() {
  local pid="$1"
  local identity

  # PID alone is unsafe because macOS can reuse it after a process exits. The
  # process start time and full command together provide a stable shell-level
  # identity that can be revalidated immediately before each signal.
  identity="$(/bin/ps -ww -p "$pid" -o lstart= -o command= 2>/dev/null)" || return 1
  [[ -n "$identity" ]] || return 1
  printf '%s' "$identity"
}

taskscope_process_start_time() {
  local pid="$1"
  local state
  local start_time

  # The start time survives exec, so PID plus start time follows a forked
  # child from the shell into the program it runs. Exited zombies do not count.
  read -r state start_time < <(/bin/ps -p "$pid" -o stat= -o lstart= 2>/dev/null) \
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
    /usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null \
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
  /bin/ps -ww -axo pid=,command=
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
    [[ "$any_running" -eq 0 ]] && return 0
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
    [[ "$any_running" -eq 0 ]] && return 0
    taskscope_pause 0.1
  done

  echo "Could not stop every verified TaskScope process for $canonical_executable." >&2
  return 1
}
