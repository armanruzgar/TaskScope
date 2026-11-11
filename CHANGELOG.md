# Changelog

All notable changes to TaskScope are documented in this file. The project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Added a **User** column and per-second network and disk columns (**NET KB/S** in / out, **DISK MB/S** read / write) to the window's process list. Account names come with the list read; rates are averaged since the previous refresh and show a dash until the second one. All three columns sort, and VoiceOver reads them. The window's minimum width is now 830 points.
- Added to Process Detail the parent's name, the elapsed time, the kernel executable path, the code signature (signing identifier and Team ID, or Apple, ad hoc, or Unsigned), and, for your own processes, threads, open files, and listening TCP and UDP ports. They are read from the kernel without starting another program, between two checks that the PID still belongs to the row's process. Every value can be selected, and a value macOS does not give reads **Unavailable** with the reason.
- Added **Copy Command Line** to a process row's context menu and VoiceOver actions, and renamed Process Detail's **Arguments** row **Command Line**. Both read the command line only on request, and only while the PID still has the row's start time and executable path, checked before and after the read. When the PID now belongs to a different process, Copy copies nothing and says so without showing the command line; a copied command line is marked confidential for clipboard managers.
- Added command-line search for your own processes: search text also matches their command lines, ignoring case and across arguments, read in memory only while the search field has text and never shown. A row found only that way shows a magnifying-glass mark; other users' command lines are not searched.
- Added sorting by every column title: a click sorts by that column, a second click reverses it, and a chevron and a VoiceOver value show the direction. The Sort menu offers CPU, Memory, Name, PID, Parent PID, User, Network, and Disk, each ascending or descending; the direction is saved with the sort, and rows without a value stay last.
- Added **Copy Visible Rows** (tab-separated text with a title row) and **Export Visible Rows…** (a CSV file) to a row's context menu, its VoiceOver actions, and the **Process** menu. Neither includes command lines, and text that starts with `=`, `+`, `-`, or `@` gets a leading apostrophe so that a spreadsheet keeps it as text.
- Added **Stop With Children…**, **Pause…** and **Resume**, and a **Send Signal** submenu to a row's context menu. Stop With Children lists the process and its descendants in the Stop Selected review and stops each one after checking its identity again, never as a process group; it leaves out a descendant it may not signal, with everything below it, and says how many. Pause sends `SIGSTOP` after a confirmation and Resume sends `SIGCONT`, and a paused row shows a **Paused** badge; Send Signal sends Hangup, Interrupt, User 1, or User 2, each confirmed like Stop. These actions reach only your own processes, never TaskScope, launchd, GlobalProtect, or a macOS system component.
- Added **Restart…** to custom preset cards: it quits the app and its helpers and then opens it again, under one confirmation and one report, and opens nothing if the quit does not complete. It is not offered while the preset is kept off.
- Added Keep Off to every preset. A custom preset's **Keep *name* Off** switch persistently disables its user launch agents in your login session and stops its app and helpers, and background enforcement stops them again whenever they appear. It signals only your own processes inside the preset's app bundle, never asks for administrator approval, and never changes system launch daemons; the built-in GlobalProtect preset keeps its disconnect, system-service step, and Stop Services Anyway. Keep Off is stored per preset, and the earlier Keep GlobalProtect Off setting migrates. A preset whose Keep Off is on, still running, or unknown cannot be edited or deleted, and an imported preset never arrives kept off.
- Added Auto-Stop conditions on sustained CPU use (100% is one core) and resident memory, each held for a set number of 10-second checks in a row (3 by default), and on plain, case-sensitive text in the command line. Run time becomes an optional floor, a rule needs run time, CPU, or memory, and prompts, Log Only records, and the event history say which conditions matched. Command lines are read in memory and never stored or logged. TaskScope 1.1.0 keeps rules with the new conditions turned off and read-only.
- Added the **Get Watched App Status** Shortcuts action and its App Shortcut, "Get *preset* status in TaskScope". It is read-only and returns the preset's name, whether its main app is running, how many of its helpers are running, whether Keep Off is on, and whether that status is current, stale, or unknown; **Open Watched App** and **Stop Watched App** return the same value. Keep Off and administrator operations stay out of App Intents.
- Added state marks to the menu-bar icon: a dot for a running watched app, a warning triangle when a kept-off preset's service or user agent is running again, a question mark when watched status is unknown or stale, and a bell for a waiting Auto-Stop prompt. The icon keeps its width, and VoiceOver names the state. **Settings > General > Show status in the menu-bar icon** (on by default) turns the marks off. While the icon is the only reason to read in the background, TaskScope reads watched status every 30 seconds, or at the watched status interval when that is longer.
- Added **Settings > General > Configuration Backup**. **Export Configuration…** saves the presets, Auto-Stop rules, saved selections, general settings, and hotkey to one file (schema version 2, at most 1 MB), never Keep Off, recovery backups, or the event history. **Import Configuration…** previews each part with a switch, validates it as its store does, brings Auto-Stop rules in turned off, and never turns on background enforcement; it also reads older preset archives.
- Added `script/render_screenshots.sh`, which renders the README screenshots, now including Process Detail, from synthetic data with the app's own views drawn off screen. Nothing is launched, no window is shown, and the screen is never captured.

### Changed

- Label the window's history charts **CPU SUM** and **RSS SUM**, show each sum's latest value and its peak in the time window with the span beside them (for example "last 10 min"), place samples by time, say in text when history is paused or unavailable, and keep the samples still in the time window when the window reopens.
- Read the process list with one `ps` instead of two: an in-process read of the kernel's process table checks each row's PID and start time, so exited (zombie) processes are no longer listed and a process named `<defunct>` is not mistaken for one.
- Check every staged, installed, and released bundle's Info.plist values and its App Intents actions, entities, queries, enums, and App Shortcut phrases against one list, `script/expected_intents.json`. Installs and releases now refuse a bundle whose metadata differs from the checkout, and Settings > Health applies the same rule.
- Write one debug line per Auto-Stop engine pass, with only the number of processes read, to the Unified Log's `AutoStop` category. Measured windowless in the background, passes stayed within about a second of their 10-second cadence, so TaskScope holds no App Nap exception.
- Save stored JSON arrays that keep a newer build's fields through an identity index, so a 10,000-event history is saved in about 0.04 seconds.
- Split the tests into `TaskScopeTests`, which builds and runs without ViewInspector, and `TaskScopeViewTests`, the only target that uses it. `swift test`, the strict step, and CI run both, each in its own process, and `DocumentationConstantsTests` fails when a document stops stating a value the code defines.
- Show the current window, menu-bar popover, and Process Detail in the README screenshots, rendered from synthetic data.

### Fixed

- A launch while TaskScope is quitting no longer hands off to the quitting copy and exits, which left no TaskScope running and showed nothing. The running copy holds a per-user lock file, `~/Library/Application Support/<bundle id>/Instance.lock`, and lets it go while quitting, once its settings are saved and no action is running; the system drops it after a crash. A new launch hands off only to the copy that holds the lock, waits up to about ten seconds for a copy that is still finishing an action, and otherwise starts normally, even while the quitting or crashed copy is still listed. When two copies start together, the one that takes the lock keeps running. Startup verification never takes the lock. Only when the lock cannot be used does the earlier-start rule decide, as in 1.1.0.
- Show the main window when TaskScope is opened from the Dock or Finder. While it decided how it was launched, TaskScope made itself a menu-bar-only app, which handed the front back to the previous app at once, so the window waited for a second click.
- Draw tree rows when Tree View is turned on after the flat list was shown; the flat rows stayed on screen without indent or disclosure buttons, so a parent could not be expanded.
- Match the executable path shown under each process name when the search text contains a slash or starts with `~`, as shown or in full.
- Read a main-window row's parent PID, user, and network and disk rates to VoiceOver.
- Show what a preset's Quit App, Quit Helpers, or Quit App and Helpers is doing while it runs, instead of an earlier result.
- Keep an unanswered Auto-Stop prompt in its place when its process's executable moves, without recording an "identity changed" failure for it.
- Use Activity Monitor's search field when its window appears only after the first selection attempt, so a saved search no longer hides the row for the rest of the handoff.
- Name ⌘⇧Tab, not ⌘Tab, when that hotkey is refused, say "1 selected process" when saving a one-process selection, and report a command that could not be started as "Could not start the command: …".
- Keep a confirmed Stop Now from prompting again for the same process when its Prompt rule is edited, saved, or switched off and on while the stop is still running.
- Show a preset stop's relaunch-job report when the stop has finished, not while its processes are still being stopped.
- Close every pipe of a command that could not be started before reporting the failure.
- Keep test runs from asking for Contacts access or trying to open the Contacts database, and from ending early when a view test taps Quit.

### Security

- Start child commands without inherited variables that change what a shell runs, exported bash functions, or `DYLD_*` variables, so a value set for the login session cannot change what the elevated `/bin/sh` of an administrator request runs.
- Run every command TaskScope starts, including `ps`, `nettop`, `launchctl`, `open`, and the administrator `osascript` request, as an argument vector with no shell in between, so no value can be read as shell syntax. An administrator request passes its AppleScript to `osascript` as one argument; the script text and the macOS prompt are unchanged.

## [1.1.0] - 2026-11-10

Source/development release with the fixes from the November 2026 audit. Build
metadata is `1.1.0 (3)`. Like 1.0.0, it does not include a Developer ID-signed,
notarized, universal, or public binary.

### Added

- Added a confirmed, persistent Keep GlobalProtect Off switch to the built-in GlobalProtect preset. It disables and unloads the fixed `pangpa` and optional `pangps` user launch agents and, with macOS administrator approval, disables and boots out the fixed `system/com.paloaltonetworks.gp.pangpsd` VPN daemon; GlobalProtect Quit All and Stop Services Anyway use the same path. Open or turning the switch off restores the services.
- Added Settings > Health with expiring, read-only permission, signing, metadata, path, and bundle-identity checks and navigation-only recovery.
- Added previewable support diagnostics with exact JSON copy/save and at most 20 redacted lifecycle failures retained in memory.
- Added a read-only GlobalProtect Compatibility Self-Check with version, fixed-job, override, ownership, and protected-service observations.
- Added versioned preset archives, bounded reads, legacy-array import, field review, and non-mutating lifecycle previews.
- Added **Show all processes** to Settings > General; with it on, every matching process is listed in any sort order and in tree view.
- Added an **Arguments** row to Process Detail with the process's full command line, read only when the sheet opens and kept only if the process still has the row's start time.
- Added list keys and VoiceOver support: Space toggles the keyboard row's selection, Left and Right Arrow collapse and expand tree rows, Command-I shows detail, rows offer their context-menu actions in VoiceOver's Actions rotor and report focus, tree level, and PID, and footer results are announced.
- Added sorting by the CPU, MEM MB, and PID column titles, which mark the active sort.
- Added a one-line summary, selectable text, and **Copy Report** to Stop and service results; Escape closes them, and a newer report waits until the one on screen is closed.
- Added `-h`/`--help` to `build_and_run.sh`, `install.sh`, and `release.sh`, `TASKSCOPE_OUTPUT_DIR` for an absolute staging directory, and `--evidence-only`, `--packaging-only`, and `--pipeline-only` to `test_release_compatibility.sh`.
- Added a quality-gate step that fails on any compiler warning in the package's sources and tests, because some Swift 6.4 concurrency diagnostics stay warnings under `-warnings-as-errors`.
- Added **Restore Built-in GlobalProtect Preset** to Settings > Watched Apps, shown while the built-in preset is missing.
- Added **Help > Welcome to TaskScope** (Command-?) to reopen the introduction, which now also covers the menu-bar item, the current global shortcut, and the Accessibility access and administrator approval that Quit All and Keep GlobalProtect Off can ask for. It replaces the Help item that opened a help book the app does not have.
- Added menu commands: File > Refresh (Command-R) replaces File > New, which opened duplicate main windows; Edit > Find… (Command-F) focuses the search field; View > Tree View, Processes, and Presets; and a Process menu with Show Detail (Command-I), Stop…, and Force Stop…, which still ask for confirmation. Edit > Select All adds the displayed matching rows when the list has focus.
- Added a Unified Log record, in the `Actions` category, of every signal TaskScope sends and every launchd change, app open, and administrator request it runs, with its outcome; process names and command lines are private.
- Added to Settings > Health's signing row whether an intact signature has the hardened runtime.

### Changed

- Use diagnostics schema version 2 with `null` for unreadable saved notification and Keep Off settings; document `disconnectFailed` and shipped action mappings.
- GlobalProtect Quit All and explicit Keep Off disconnect before stopping known services, including fixed system disable/bootout with administrator approval where supported.
- Turning Keep Off off performs the same full service and app restoration as Open, preserving the unused system override on session-agent layouts.
- Limit disconnect observation to about 30 seconds (60 observations with 0.5-second waits plus reads), inside a 90-second deadline that also bounds Accessibility requests; timeout leaves services running.
- Offer separately confirmed Stop Services Anyway after disconnect failure, disclosing networking risk and Open recovery.
- Show GlobalProtect full-stop progress and results in the regular window, including actions started from the menu bar.
- Background Keep Off disables both fixed user jobs but unloads only the interface agent; preserved PanGPS does not trigger polling stops or failed background session stops.
- Preserve loaded or uninspectable system daemons on session layouts with an incomplete-stop report and advice that reflects that policy.
- Set the default hotkey to Control-Option-Command-T while retaining supported saved combinations; migrate all invalid saved shortcuts with a persistent reason.
- Show quick-rule executable or name-wide scope and disclose when adding a path enables a disabled name-only Auto Stop rule.
- Preserve unknown JSON fields and newer settings values across saves; disable and lock rules whose unknown fields may narrow their authority.
- Preserve wrong-type preferences as binary property-list backups and partially rejected data in numbered recovery slots until explicit reset.
- Recover valid saved selections and events from mixed arrays; retain unknown selection fields and commit recovered state only after reset.
- Keep configured presets visible before observations and after read failures, with Unknown/Stale status, read errors, and Retry.
- Show truncated flat/tree/search lists as Showing N of M.
- Refuse script launches of a different bundle path while the same identifier is running, including debug/log modes and installer launches.
- Stop verified staged copies before replacement; hold the packaging lock through verification and install copying, then recheck identifier, version, and build.
- Use unique packaging-test preference domains, reject leaked preference files, and remove test domains and plists during cleanup.
- Accept whitespace-only evidence-manifest lines and report CRLF and UTF-8 BOM errors with correction instructions.
- Require candidate-bound lifecycle evidence for public-binary releases and build numbers greater than every existing version tag.
- Run the quality gate's script-syntax, debug-build, test, strict-concurrency, and compiler-warning steps in GitHub Actions (Xcode 26.6 on `macos-26`) on every push to `main` and on pull requests; code coverage, the release build, and the packaging test still run only locally. Retain weekly dependency updates and use a per-checkout strict-build directory.
- Reorganize public documentation, document private reporting, and clarify uninstall cleanup for persistent user and system launchd overrides.
- Ask for menu-bar confirmations in an app-modal alert that brings TaskScope forward; the regular window keeps its in-window dialogs. New lifecycle and batch reports wait until their window is in front, so the Dock icon no longer bounces after GlobalProtect on/off actions.
- Stage the app at `dist/build.noindex/TaskScope.app` instead of `dist/TaskScope.app`, so Spotlight does not index the build; release archives stay in `dist/releases`.
- Auto-refresh process list also performs the first list load; a list that is not auto-refreshed shows when it was last updated.
- Read watched status in the background only while notifications or Keep GlobalProtect Off need it, otherwise only while a window or the popover is open, and refresh at once when one opens. An Auto-refresh tick reads the process list once, and the history charts reuse each poll's read instead of running their own read loop.
- Stop and Stop Selected wait up to three seconds for a process to exit after `SIGTERM` before reporting it still running, and never escalate; Stop confirmations say that apps can quit without asking to save changes.
- Preset stops stop the main process first and then give all helpers one shared three-second window, so an action waits about six seconds at most instead of three seconds per helper name.
- Batch Stop reviews list every captured target with PID and path, rows on screen first, and say how many are hidden; summaries lead with the stopped count and list only nonzero remainders; a finished batch deselects only its own targets.
- Escape clears only the keyboard row, and Command-A adds the displayed matching rows to the selection instead of replacing it.
- Tree view follows the Sort setting at every level, with name and then PID breaking ties, opens the path to every displayed match, dims ancestors shown only for context, and counts visible rows.
- Open brings an already-running app to the front instead of reporting "Opened" with no effect; GlobalProtect is never opened over its running interface.
- Refused stops say why, in the same words as Auto Stop, also for each row of the Stop Selected report.
- Presets for different bundles may share a main process name; presets must still differ in display name and app path, notifications name the preset for a shared name, and duplicate messages name the field and the other preset.
- Limit preset archives, Add, and Import to 200 presets; stored lists above the limit still load.
- Keep a preset's app path as entered and follow its links when matching and opening, so a re-pointed link or a later install is picked up and a changed link cannot lock the preset store.
- Allow one auto-stop rule per process name, compared case-insensitively; Duplicate adds a switched-off copy.
- Add Rule and Edit refuse a path as the process name and a directory or app bundle as the executable path, suggesting the bundle's executable, and mark paths that do not exist yet.
- Record one failure event, with a Force Stop hint, when a confirmed Stop Now's process still runs one engine cadence later, and keep tracking its exit across edits, toggles, and deletion. An Auto Stop retired while its process exits records that the exit will not be tracked.
- Ask Prompt rules in an app alert even when no TaskScope window or popover is open; the alert shows the runtime as a duration and says that Dismiss stops reminders for that process until it restarts.
- Process Detail tells a process that is gone, a PID that now belongs to another process, and a failed read apart, offers Retry, and shows current CPU and memory.
- The Presets section shows a recovery notice instead of an empty list when stored presets are unreadable or partly rejected; card actions are unavailable while another action runs, Quit Helpers is unavailable with nothing to stop, confirmations name the preset, and only the built-in GlobalProtect preset shows the shield.
- The footer's Σ shown total covers the displayed matching rows and is hidden on Presets; its spinner shows only for actions and explicit refreshes; Quit is unavailable while an action runs; long results wrap.
- Mark over-threshold values with a glyph and weight instead of red text alone, explain the NET and DISK pairs, show PIDs without digit grouping, and use the singular for one.
- End commands that open a dialog with an ellipsis; offer Watch This Process only for your own app processes running from an app bundle's `Contents/MacOS`.
- Name TaskScope, the GlobalProtect system VPN service, and the change in every administrator prompt; ordinary GlobalProtect stop results say when PanGPS is still running and the VPN was not disconnected.
- Background enforcement leaves GlobalProtect's interface open for three minutes after a failed explicit disconnect asks you to complete its request.
- Build the app from a generated app-only package, so packaging never resolves ViewInspector or rewrites `Package.resolved`; read the deployment target from `Package.swift`, require Xcode 26 or later with a clear message, add the standard Info.plist keys, and enable complete concurrency checking for both targets.
- `install.sh` checks the destination and same-identifier launch conflicts before building, prints build progress, treats a failed final open as a warning, and says when a failed upgrade left TaskScope quit; unknown or extra script arguments are usage errors.
- `release.sh` requires an explicit `--preflight` or `--release`, refuses an existing `v<version>` tag or leftover `[Unreleased]` entries, matches the changelog heading literally, puts the build number in artifact names, strips distributed binaries after extracting their dSYM, requires a pushed default-branch `HEAD`, records the branch and remote in provenance, removes failed work by default, and stages in its own work directory; a first release without tags needs `TASKSCOPE_FIRST_RELEASE=1`.
- The release evidence gate requires manifests directly in the candidate directory, one per environment, real test dates, and distinct artifacts that are not manifests.
- Packaging tests sign ad hoc and stage in their own temporary directory, never the checkout's `dist/`.
- Point published links, issue templates, and the private-report link at `github.com/armanruzgar/TaskScope`.
- State that TaskScope has a single maintainer; conduct reports go through the private reporting form, marked as conduct reports, and concerns about the maintainer go to GitHub's abuse reporting.
- Document that Dependabot alerts and security updates are on and that a Dependabot pull request is merged only after its CI checks and the full local gate pass; repository rulesets block force-pushes to and deletion of `main` and moving or deleting `v*` tags.
- Tests keep settings in in-memory defaults, so parallel runs cannot collide and runs leave no `TaskScope.*` preference files.
- Ask for confirmation before deleting a preset, an auto-stop rule, or a saved selection and before clearing the event log; rule rows show Edit…, Duplicate, and Delete… buttons and report a refused change on the row, and Settings lists every retained auto-stop event.
- Accept a typed rule runtime in minutes (1 to 1,440) in Add Rule, the Edit sheet, and the quick rule sheet.
- Name the reset button for unreadable data **Discard Unreadable … and Reset**, with a confirmation, when nothing could be backed up.
- Keep Dry Run and the Compatibility Self-Check available while presets are in recovery; only editing is locked.
- In the quick rule sheet, name the binary a path-bound rule covers now and after an Update, drop the old name's path when Update renames the rule, and refuse processes owned by another or an unknown user.
- Report an import with a neutral summary of imported and rejected presets, and clear the previous outcome when Import opens again.
- Make the About version line selectable; a build without a bundle version says so.
- Close read-only sheets with Escape, place Cancel beside the primary button, name the preset or rule on Dry Run and Edit buttons, hide empty Helpers and Protected lines, title the notifications switch Notify, explain how to add a rule in an empty Rules list, and give the General sliders accessibility names and values with units.
- Quitting during a lifecycle action stops polling and Auto Stop rules, waits up to five seconds for the action, then stops the commands still running; with nothing in flight TaskScope quits at once, so a stuck action delays quit or logout by about six seconds at most.
- After a quiet launch (login item, URL, or Shortcut), closing the last TaskScope window removes the Dock icon again; About and the welcome window are single windows.
- Save the list's filter and tree view across launches, shared by the window and the popover, like sort and search.
- The Shortcuts Stop confirmation names the launch agents it unloads and says that it sends `SIGTERM` and force stops a process still running three seconds after the stop request.
- With unreadable settings, the GlobalProtect card shows Keep Off as Unknown and says that background enforcement is paused.
- Send at most one notification per preset and direction per refresh, replacing the older one; do not announce changes caused by TaskScope's own Open, Quit, and explicit Keep Off; keep notifications shown while TaskScope is in front in Notification Center; and resume delivery at the next refresh after notifications are allowed.
- After a successful Activity Monitor handoff, keep the search and scope that show the row and hide a PID column TaskScope showed after about four seconds; restore changed fields only after a failed handoff. Selection gives up after about five seconds, reporting "Activity Monitor is not responding." when it stopped answering, and overlapping handoffs run one after another.
- Take hotkey recording keystrokes only from the Settings window, cancel recording when that window loses focus or closes, and pause the current hotkey while recording; refuse Control-letter keys and Command with an arrow, Delete, Forward Delete, Return, or a digit.
- Stop Health file and signature checks after 10 seconds, reporting a still-blocked check as pending instead of starting it again.
- Call a custom preset's full stop **Quit App and Helpers** on its button and confirmation, in the dry run, and in its result messages, instead of Quit All Killable, Close All, and Close; support diagnostics still record it as `close`, Shortcuts still call it Stop Watched App, and GlobalProtect keeps its stronger Quit All.
- Rename the row action Copy Command to **Copy Executable Path**, which is what it copies.

### Fixed

- Allow identity-verified Activity Monitor handoffs for visible root-owned and other-user processes.
- Reopen the existing TaskScope window when rejecting a duplicate launch, including quiet login-item instances.
- Suppress default App Intents watched-app targets when stored preset preferences have an unreadable property-list type.
- Retry shell child reaping after early exit notifications and command stops, including timeouts, so completed commands do not hang lifecycle actions.
- Stop shell output reads at EOF, handle interrupted reads, and preserve cancellation/exit results without leaking running children.
- Use monotonic time including sleep for shared inventory freshness and ordering, and bound Open polling with a monotonic deadline and attempt limit.
- Align watched status, the Watched filter, and preset stops with current-user ownership and main/helper executable-directory boundaries.
- Preserve UTC start evidence and UTF-8 names, parse padded timestamps, and reject incomplete, empty, or duplicate-PID inventories safely.
- Distinguish changed process identities from absent PIDs; executable moves cannot falsely produce Auto Stop Ended/Stopped events or revive dismissed prompts.
- Publish verified inventory after a stale single-process stop, preserve extended Net/Disk readings, and update the displayed-list timestamp only when its backing inventory is replaced.
- Track watched-snapshot freshness separately and include the date for stale observations before today.
- Treat exited (zombie) processes as already exited across manual, batch, and automatic stops, without signalling them. Exit comes from the kernel's process state, read with the inventory; because a live process can name itself `<defunct>`, that name without a kernel executable path counts only when the state cannot be read.
- Preserve unanswered name-only prompts after executable moves while keeping explicit dismissals attached to the process lifetime.
- Avoid failure events for automatic stops cancelled before signalling by a rule edit; retain accepted-request retry budgets across edits that keep Auto Stop enabled and matching.
- Report definitive user-agent bootout refusals after one verification read while retaining bounded waits for in-progress or uncertain replies.
- Treat complete GlobalProtect job listings with state but no top-level PID as non-running while retaining unknown attribution for malformed output.
- Strengthen inventory-failure regressions to require unverified targets and the current verification-failure messages.
- Report explicit refresh results when joining silent reads, without treating cancellation or an unrelated prior error as the refresh result.
- Reject queued cancellations without failure diagnostics; finish admitted preset Stops and keep Open readiness cancellable with truthful partial-change messages.
- Verify Quit App, Quit Helpers, and Quit App and Helpers against the captured preset even if its stored definition changes or is deleted.
- Verify user-agent removal after nonzero bootout exits; still-loaded or unreadable final states remain failures.
- Recover required GlobalProtect overrides on Open without saved intent or an app bundle, reporting missing-bundle and recovery failures together.
- Report service restoration only for observed changes and suppress the service sheet for healthy unchanged GlobalProtect Open.
- Avoid successful Quit claims when relaunch jobs fail and processes remain running or unverified; partial failures do not claim no signal was sent.
- Block every Keep Off intent writer while settings are unreadable, including Quit All and Stop Services Anyway, with a reset explanation.
- Block built-in preset deletion during queued/running Keep Off and recheck preset existence and writable settings after disconnect before changing intent or services.
- Attribute PanGPS through fixed launchd PID, ownership, and kernel executable path before automatic disconnect and final Keep Off verification.
- Suppress repeated unchanged background Keep Off reports, status replacement, and diagnostics, while reporting user-job and system-verification failures.
- Require five consecutive idle disconnect observations after a Connected observation resets the streak.
- Restore root-running session PanGPS through its installed job, bound readiness/shutdown waits, and retain Keep Off intent after failed user-job restoration.
- Recover orphaned GlobalProtect UI after restoring its service, preserve healthy services, and avoid duplicate UI or force-restarting loaded jobs.
- Keep ordinary GlobalProtect Quit and Shortcuts Stop scoped to interface/user processes; Quit Helpers preserves an agent running the main process.
- Limit Prompt, Auto Stop, and Log Only to current-user processes, excluding TaskScope and unsignalable PIDs, and distinguish safety refusal from kernel refusal.
- Wait a full engine cadence before the single automatic retry and retain handled state and retry budget across still-matching edits, including after signal delivery.
- Preserve delivered stop history across rule edits/removal and require durable Log Only storage before marking an occurrence handled.
- Validate quick watched presets against every selected process's owner, name, and executable directory without fabricating paths for non-bundled tools.
- Preserve rejected event payloads and recovered events plus retained session history when explicitly resetting the event log.
- Refuse preset recovery exports when no valid presets remain and explain exclusions from partial recovery exports.
- Follow Health path symlinks with bounded regular-file reads and classify dangling targets as missing.
- Preserve seven-digit and longer TaskScope build numbers in compatibility reports using a positive-integer validator up to 64 digits.
- Hand off duplicate same-user, same-bundle launches before preference writes, commands, hotkey registration, or background enforcement.
- Isolate startup-verification stores and onboarding in volatile defaults without reading or changing normal preferences.
- Route SIGTERM through normal termination so pending search saves and Activity Monitor restoration can complete.
- Keep entity queries and late intent launches in the background without demoting an already-interactive app; require Stop confirmation through Siri, Spotlight, and App Shortcuts.
- Reschedule history cadence changes without immediate sample bursts, and show the packaged icon in About and onboarding.
- Add Turn Off Launch at Login in the Requires Approval state, and Remove Stale Login Item in the Unavailable state, which now says that macOS has no login item for this copy, so removal and errors are reachable from Presets.
- Keep refused hotkey recordings separate from registration/conflict status; preserve unknown hotkey fields and disable unreadable hotkeys until explicit reset.
- Verify captured start time and kernel executable path throughout Activity Monitor handoff, and describe Accessibility as not granted without assuming denial.
- Retarget consecutive Activity Monitor handoffs while respecting later user changes.
- Re-baseline watched notifications after preset identity, path, process-assignment, or notification-setting changes.
- Resolve preset card quit actions against current configuration and render unobserved/stale cards without implying a verified quiet state.
- Disable quick rule/preset creation and stop actions on TaskScope's own row and preserve identity checks during force escalation.
- Request keyboard focus on every tree-row tap, including repeated selected-row taps and recursive children.
- Preserve hidden/search selections across refresh and sort changes, reconcile against full inventory, and bind batch confirmations to captured targets.
- Recall a saved process that still runs by its PID and start time, even when more copies of its executable run; leave an executable's remaining entries unselected, and listed as ambiguous, when more unselected copies run than entries. Path-backed selections never downgrade to legacy matching.
- Preserve optional preset job requirements, including when an edit changes only an agent's label or plist path; adopt the bundle executable's spelling for main process names, exclude main processes from helper lists, and reject ambiguous comma-containing fields.
- Correct prompt target presentation, saved-selection read errors, stale-list recovery, settings-sheet validation, and accessibility labels.
- Judge administrator system-daemon stops by a fixed disable-phase marker and bounded final launchd inspection; report cancelled or denied approval and failed disables after one inspection, and accept a nonzero bootout once the daemon is verified gone.
- Require Prompt, Auto Stop, and Log Only thresholds to be reached on the kernel's monotonic process clock as well as `ps etime`, so a forward wall-clock step cannot make a rule act early.
- Size the process list's Sort and filter pickers to their content so the sort key no longer truncates on macOS 26, and wrap the saved-selection and stop controls onto a second row when the menu bar popover is too narrow for one.
- Keep the stale process-list banner until the list itself reloads; watched-status reads no longer clear it.
- When an automatic launch hides its window, hand activation back only while TaskScope is active, and to the app that was most recently frontmost.
- Let a command that joined a read cancelled midway run its own work instead of treating that read as delivered.
- Clear a pending preset confirmation when that preset is edited.
- Explain why renaming a saved selection that was deleted fails.
- Treat a legacy recall entry whose candidates are all claimed by other entries as unmatched.
- Clear stale Settings errors after a cancelled rule edit, a deletion refusal, or an export after reset, and show when the notification toggle is rejected.
- Look for Activity Monitor's search field in its process-table window.
- Keep an import candidate rejected as a duplicate from reserving its preset ID.
- Name a process whose command is not an absolute path but contains `/` by its leading token, for example `sshd-session` for `sshd-session: user@ttys001`.
- Drop history-chart samples taken before a pause, and keep the Unavailable state across sampling-interval changes.
- Make the packaging scripts always stop the startup-verification child, and refuse to launch while a copy running from the bundle path is an older, replaced build.
- Keep App Intents and entity queries from demoting a launch you activated or reopened, including during the launch grace period; TaskScope's own App Shortcuts refresh waits until a launch has settled.
- Stop every shell command still running when TaskScope quits, within about a second, and start no new ones; a command stop keeps signalling its process group until it is empty, so a fork cannot leave a survivor.
- Report "Too many open files" when a command's pipes cannot be created, and complete a command whose exit status was collected elsewhere (`ECHILD`) with a clear error, without signalling it again.
- Share a slow inventory read by measuring cache age from its completion; a cancelled caller returns at once, and a shared read is cancelled only when nobody waits for it.
- Verify a single Stop's target with a basic read and keep the Net/Disk values already shown.
- Show the Presets stale banner only after watched-status read failures, and keep silent background reads from showing progress in the footer.
- Say in Open's late failures that Keep Off was cleared and services restored, never claim a launch that did not happen, and stop lifecycle failure summaries from ending in "..".
- Decide Keep Off enforcement from each tick's fresh read instead of a second uncached read.
- Read every `launchctl print` through one parser that finds the job's PID by indentation; a job counts as absent only on exit 113 with that label's not-found text, and Quit Helpers leaves loaded, and reports, an agent whose PID cannot be read.
- Start a loaded but idle GlobalProtect session job once with a plain `launchctl kickstart` during Open, decide each bootstrapped agent from launchd state, and report a failed start of an already-loaded job as a warning.
- Complete Keep Off on a login-session install without a `pangpsd` plist when launchd confirms that nothing is loaded.
- Name timed-out, cancelled, and denied administrator requests plainly; after a timed-out stop or re-enable, launchd's state decides the result.
- Count a Disconnect press that times out as unconfirmed and keep observing.
- Report that launch agents were unloaded when no process was running but a job was booted out, and show `open`'s error or the timeout when an app launch fails.
- Verify the login-session PanGPS separately in the compatibility self-check, without implying that a root PanGPS is the system daemon.
- Keep Preview & Recall from stalling the main thread for selections spanning many executables; rank names once per refresh and bound the per-query list caches.
- Export presets as stored, keeping fields from a newer build, and keep an agent's optional flag when an edit changes only its label or plist path.
- Back up, and stop writing over, settings that became unreadable after launch; use payloads holding a value this build cannot write back read-only, with a backup, in every store; load stored rules or selections that repeat an ID into read-only recovery.
- Stop delaying prompts and Log Only records while an Auto Stop waits for another operation, stop reporting PID reuse after an exit as an identity change, and save the event log once per engine pass.
- Log a process only once per lifetime for a Log Only rule, also when its executable is moved or renamed while it runs.
- Keep menu-bar alerts from blocking main-actor work and re-check their request after the answer; queue a preset card's Open in click order.
- Show the current runtime in a queued Auto Stop prompt, and clear the quick rule sheet's error when it closes.
- Show when chart history is unavailable, and start a new chart segment after a failed read.
- Bring TaskScope forward when Settings opens from the popover, and disable saved-selection Rename, Delete, and Save during recovery.
- Wrap footer messages, write tool errors as one sentence, hide decorative images from VoiceOver, and keep Retry a separate element in error states.
- Run `ps` and `lsof` in the script helpers under a UTF-8 locale so non-ASCII paths match; validate `TASKSCOPE_VERIFIED_BUNDLE_COPY` before any work; report the exit status and output of an app that dies during startup verification; keep App Intents metadata paths stable so unchanged sources rebuild nothing.
- Record lock owners and break a lock whose PID now belongs to another process; recover interrupted install and staging transactions under the lock.
- Clear inherited Git repository variables in `release.sh` and its tests, and render the icon in a private directory with argument checks.
- Keep script failures failing under `/bin/bash` 3.2, where an `EXIT` trap after a `set -u` abort could make a crashed script exit 0.
- Make Save Selection as Preset use the app bundle's own executable as the main process even when a helper is listed first, and keep the recall preview's buttons on screen by scrolling past 12 entries.
- Reject every command in a startup-verification instance at once and quit it after 60 seconds; hand a launch off only to an instance that started earlier.
- Accept Activity Monitor handoffs for executables under `/private/tmp`, `/private/var`, and `/private/etc`; search by the executable's file name for root-owned and other users' processes, clearing a search that could hide the row; drop prepared Activity Monitor state when Activity Monitor relaunches.
- Put hotkey preferences with a wrong-typed field into read-only recovery with a backup instead of silently using defaults, and clear an earlier refused recording's conflict status when a new recording starts.
- Clear a Support preset choice whose preset was deleted instead of building a report from it.
- Announce the menu-bar status item to VoiceOver as TaskScope.

### Security

- Bind new Auto Stop rules and durable saved selections to kernel-resolved executable paths, and include that path in the final pre-signal identity check. Legacy name-only Auto Stop rules load disabled for review after an upgrade.
- Make watched-app open and close actions fail closed when a fresh process inventory cannot be read, instead of using cached process state.
- Reject presets that repeat a launch-job label or plist path, in imported and in stored data.
- Restrict launch-agent labels to ASCII letters, digits, `.`, `-`, `_`, and `@`, starting with a letter or digit, and labels and names to 255 characters; reject control, invisible formatting, and line or paragraph separator characters in names, paths, and labels. Lifecycle actions and diagnostics skip invalid labels.
- Reject custom presets that use GlobalProtect's launch agent or daemon labels and plist paths, or the PanGPS process name, and require a `*.app` link to lead to an app bundle.
- Keep presets and launch agents with fields from a newer build read-only, refuse their actions and their import, and omit them from Shortcuts.
- Limit saved-selection names to 100 characters without line breaks, control characters, or bidirectional formatting characters.
- Spawn shell commands with `/dev/null` as standard input and no inherited app descriptors besides standard output and error.
- Require a root owner and a GlobalProtect kernel path for system-daemon readiness, and check the installed plist's label before asking for administrator approval.
- Sign every build with the hardened runtime, which blocks library injection into a bundle that may hold Accessibility trust; only `--debug` adds `get-task-allow`. Remove build-machine run paths before signing and reject non-system run paths and `@rpath` libraries.
- Refuse an install destination that is a file, a symbolic link, or another app.
- Accept only the exact URL `taskscope://refresh`, compared before URL normalization, so other spellings cannot pass.
- Drive only the Activity Monitor in `/System/Applications/Utilities` running its own executable, never a look-alike with the same bundle identifier.

## [1.0.0] - 2026-08-08

First source/development release. Build metadata is `1.0.0 (2)`. This release
does not include a Developer ID-signed, notarized, universal, or public binary.

### Added

- Native macOS process monitoring in flat and process-tree views.
- Watched-app presets with lifecycle controls and per-job result reporting.
- Graceful and forced process termination with target review and identity
  revalidation.
- Saved selections, auto-stop rules, notifications, and bounded process history.
- User-selected Shortcuts actions and a refresh-only URL automation route.
- Source builds, transactional local installation, and packaging verification.
- Maintainer release, rollback, privacy, support, threat-model, and roadmap
  documentation.

### Security

- Restricted untrusted custom-URL automation to the non-destructive refresh
  action; preset open/stop and application quit URLs are rejected.
- Hardened lifecycle configuration validation and shell argument boundaries for
  local launch-job operations.
- Preserved process identity across confirmations and asynchronous work so an
  action cannot silently move to a recycled PID or a different queued prompt.
- Preserved unreadable preference payloads and required explicit reset rather
  than overwriting them with fallback data.

### Fixed

- Report process-inventory and lifecycle failures without claiming that a stop
  succeeded or that a target disappeared when it could not be verified.
- Treat an already-missing launch-agent plist as absent during unload while
  continuing to report it as blocking when restoration requires it.
- Preserve AppleScript newlines in administrator-approved daemon restoration.
- Give the built-in GlobalProtect preset a stable identity so Shortcuts survive
  relaunches.
- Re-baseline watched-process notifications when preset process names or
  notification settings change, avoiding false "started" notifications.
- Re-check auto-stop rules after suspension points and retry actions that were
  never attempted.
- Prevent extended process metrics collection from remaining active after its
  final consumer exits.
- Keep corrupt preset, rule, event, settings, and saved-selection backups from
  being clobbered by later reads.

[Unreleased]: https://github.com/armanruzgar/TaskScope/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/armanruzgar/TaskScope/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/armanruzgar/TaskScope/releases/tag/v1.0.0
