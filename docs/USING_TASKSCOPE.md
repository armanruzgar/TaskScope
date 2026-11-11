# Using TaskScope

TaskScope has a regular window and a menu-bar popover. Both have a
**Processes** section and a **Presets** section; the window's header also shows
CPU and memory history charts. Open **Settings** with the gear button in the
header or **TaskScope > Settings…** (Command-comma). Its tabs are General,
Watched Apps, Auto-Stop, Hotkey, Health, and Support.

Each section below starts with what you do and which controls you use; the
paragraphs after that describe the checks behind each action. The
[behavior reference](#behavior-reference) collects guarantees that need no
action from you.

## First launch and general settings

On a new install the window opens on **Processes** and shows **Idle Until
Needed**: TaskScope does not read the process list until you choose **Load
Processes**, and the count line reads **Not loaded** until then. A loaded list
is a snapshot. The **Refresh** button in the header reloads it, as do Retry and
a saved selection's **Preview & Recall…**. It also reloads at every
watched-status refresh, but only if **Auto-refresh process list** is on.

**Settings > General** holds these settings:

| Setting | Default | Effect |
| --- | --- | --- |
| Watched status interval | 10 s (2 to 60 s) | How often TaskScope reads watched-app status and runs Keep Off enforcement; with Auto-refresh on, also how often a loaded list reloads |
| Auto-refresh process list | Off | Reload a loaded process list at every watched-status refresh |
| Process list limit | 80 rows (10 to 200, in steps of 10) | Rows shown; a longer result shows **Showing N of M** |
| Highlight Thresholds: CPU % | 30 % | Rows at or above either threshold are highlighted and match the **Hot** filter |
| Highlight Thresholds: Memory (MB) | 1024 MB | See CPU % |
| Notify on watched process changes | Off | Notifications for watched presets; see [notifications](#history-notifications-and-hotkeys) |

The onboarding window opens on interactive launches until you choose **Get
Started**.

## Process actions and observations

Type in the search field to match a process name, command, or PID. Use the
sort menu (CPU, memory, name, or PID), the **All / Watched / Hot** filter, and
the **Tree view** button. Select rows with the circle at the start of each row;
with a selection, the red button with the count offers **Stop Selected…** and
**Force Stop Selected…**, and **Clear** deselects. Right-click a row for
**Create Auto-Stop Rule...**, **Watch This Process...**, **Save Selection as
Preset...** (when rows are selected), **Stop**, **Force Stop**, **Show Detail**,
**Copy Command**, and **Open in Activity Monitor**.

The process list supports search, CPU/memory/name/PID sorting, filters, and flat
or expandable tree views. When the display limit truncates results, **Showing
N of M** includes the total matching rows, including search results. Command-A
replaces the selection with the displayed matching rows, and Escape clears it.
Otherwise, rows hidden by search, filter, or the display limit stay selected
until the process exits or its identity changes; batch confirmation lists
captured targets.
Click any tree row, including the selected row or a nested child, to return
keyboard focus for the [list's keys](#keyboard).

The All filter shows processes exposed by macOS. Hot shows rows at or above
either highlight threshold. Watched main processes require current-user
ownership and an executable inside the preset's `Contents/MacOS`; helpers
require current-user ownership and an executable inside `Contents`. Protected
names remain classified across users for display. This display classification
does not authorize a signal or establish a launchd service identity.

Stop sends `SIGTERM`; explicit Force Stop sends `SIGKILL`. Normal process actions
never target TaskScope itself, launchd, the kernel task, or process groups.
Captured identities are revalidated immediately before signals. Missing PIDs,
changed identities, and unavailable verification produce different results.
A changed executable path is not proof that a still-running process exited.
A `<defunct>` row with no kernel executable path is treated as already exited
and is not signalled during manual, batch, or automatic stops; a missing path
alone does not establish exit. A stale single-stop target is replaced with the
verified inventory while preserving displayed Net/Disk readings.

The displayed-list update time changes when its backing inventory is replaced.
The stale watched-status banner tracks the last successful watched observation
separately and includes the date for observations before today. Explicit refresh
reports its own result even when joining a silent read. Presets remain visible
before the first watched observation and after read failures; Unknown and Stale
status and Retry distinguish missing evidence from a quiet app.

### Keyboard

Click a row to give the process list keyboard focus. While it has focus:

| Key | Effect |
| --- | --- |
| Up Arrow, Down Arrow | Move the keyboard row |
| Return | Open the Stop review for the keyboard row (never for TaskScope's own row) |
| Escape | Clear the whole selection, including selected rows hidden by search or filter, and the keyboard row |
| Command-A | Replace the selection with the displayed rows that match the search and filter; in tree view, only matching rows shown in the tree, not ancestors shown for context |
| Command-Shift-A | Clear the selection |

Elsewhere, the global shortcut (Control-Option-Command-T by default) shows the
TaskScope window, Command-comma opens Settings, and in sheets and dialogs Return
chooses the default button and Escape cancels.

### Signals each action sends

| Action | Signals |
| --- | --- |
| Stop, Stop Selected… | One `SIGTERM` per target |
| Force Stop, Force Stop Selected… | One `SIGKILL` per target |
| Prompt rule, after **Stop Now** | One `SIGTERM`; never repeated |
| Auto Stop rule | `SIGTERM`; if the process still runs at least one 10-second engine cycle later, one more `SIGTERM`. It never sends `SIGKILL`: the event then says to use Force Stop |
| Log Only rule | None |
| Preset Quit App, Quit Helpers, Quit All Killable; GlobalProtect Quit All and Keep Off | `SIGTERM`, then `SIGKILL` to eligible processes still running after up to three seconds |

Preset stops also unload the preset's user launch agents before signalling
(Quit Helpers keeps an agent that runs the main process); see
[watched-app presets](#watched-app-presets).

### Process details and Activity Monitor

A row's context menu offers **Show Detail**, **Copy Command**, and **Open in
Activity Monitor**. Show Detail opens a read-only sheet with the name, PID,
parent PID, owner's account name, start time, `ps` command name, CPU, and
memory; it has no copy or Activity Monitor control. Copy Command copies the
process's kernel executable path, or the `ps` command name when that path is
unavailable; it never copies arguments. For a process started from a shell, the
sheet's Command (for example `sleep`) can therefore differ from what Copy
Command copies (`/bin/sleep`).

Open in Activity Monitor requests exact selection of that process.
The row's UTC start time and kernel executable path must match before opening,
on each selection retry, and after selection before success is reported. These
identity checks also support visible root-owned and other-user processes. If
Accessibility access is not granted, Activity Monitor can still open; this status
does not imply the user denied a request. Temporary search, scope, or PID-column
changes are restored after the handoff. Consecutive handoffs retain the original
state; fields subsequently changed by the user are left alone.

## Watched-app presets

Add a preset with **Settings > Watched Apps > Add**, or right-click a running
process and choose **Watch This Process...** (or **Save Selection as
Preset...** for the selected rows). Each preset in Settings > Watched Apps has
a notifications switch and **Dry Run** and **Delete** buttons, and custom
presets also have **Edit**; **Export** and **Import** handle the whole list.
Each preset card in the **Presets** section has **Open**, **Quit App**, **Quit
Helpers**, and **Quit All Killable**. On the built-in GlobalProtect preset the fourth button is
**Quit All**, a different and stronger action that disconnects the VPN and
turns on **Keep GlobalProtect Off**; read [GlobalProtect](GLOBALPROTECT.md).

The preset editor has these fields:

| Field | Meaning |
| --- | --- |
| Display name | Name on the card and in Shortcuts; the main process name is used when empty |
| Main process name | The app's main executable |
| Helpers (comma-separated) | Helper process names; each must run from inside the app bundle's `Contents` |
| Protected (comma-separated) | Names shown as protected; ordinary preset stops never signal them |
| App bundle path | Absolute path to the `.app` bundle |
| Labels | Optional user launch-agent labels, comma-separated |
| Plist paths | The matching launch-agent plist paths, comma-separated, in the same order as Labels and with the same number of items |

Quit App stops the main process, Quit Helpers stops the helpers, and Quit All
Killable stops both; protected names are excluded. The dry run calls Quit All
Killable **Close All**, its result messages say **Close** (for example "Close
did not complete."), support diagnostics record it as `close`, and the **Stop
Watched App** shortcut runs the same stop.

Settings supports creation, editing, ordering, import, export, and a lifecycle
dry run. Exports use a versioned archive; legacy array imports remain accepted.
Import is size-bounded and previews configured fields and rejection reasons
without changing processes. A later user action can use those app paths, user
launch-agent labels/plist paths, and process names, so inspect untrusted imports.
Custom presets cannot configure privileged system daemons; the built-in
GlobalProtect privileged definition is immutable.

Helper/protected names and launch-agent labels/paths cannot contain commas.
Names can have at most 255 characters. A launch-agent label must start with an
ASCII letter or digit and contain only ASCII letters, digits, `.`, `-`, `_`,
and `@` (at most 255 characters). No name, path, or label can contain control
characters, invisible formatting characters such as zero-width spaces or
bidirectional overrides, or line or paragraph separators. These rules apply to
the editor, import, and stored presets; a stored preset that breaks them is
handled like other invalid stored data (see
[recovery](../SUPPORT.md#stored-data-is-unreadable)).
Custom app paths use their on-disk spelling; main process names adopt the bundle
executable's spelling, and helper lists exclude the main process. Optional job
requirements survive normalization and saves.

**Watch This Process** and **Save Selection as Preset** validate every selected
process against the proposed main/helper name, owner, and executable-directory
boundaries before saving. Non-bundled tools receive no fabricated app path.
Extensions and XPC services can be helpers alongside their containing app's main
process, but are not accepted as that main process. TaskScope's own row disables
Watch This Process and Create Auto-Stop Rule.

Open and preset stop actions share lifecycle checks and per-job reporting. Quit
App, Quit Helpers, and Quit All Killable verify final inventory against the
definition captured for the action even if the saved preset changes or is
deleted. Preset stops and GlobalProtect's Quit All and Keep Off give eligible
processes up to three seconds to exit before force stopping; confirmations
disclose escalation. Partial reports do not imply every target stopped or that
no signal was sent.

For GlobalProtect's distinct full-stop and restoration behavior, read
[GlobalProtect](GLOBALPROTECT.md). Ordinary Quit App, Quit Helpers, and Shortcuts
Stop do not disconnect it and leave its VPN services alone.

Deleting the built-in GlobalProtect preset is refused while Keep GlobalProtect
Off is on, while an explicit Keep Off action is queued or running, and while
settings are unreadable. A relaunch does not recreate a deleted built-in
preset; importing an earlier export that contains it restores the built-in
definition, so export your presets before deleting it.

## Runtime rules

Create a rule under **Add Rule** in **Settings > Auto-Stop**: enter the process
name, an executable path (required for Auto Stop), the runtime in minutes (1 to
1,440), and the action. You can also right-click a process and choose **Create
Auto-Stop Rule...**. Once a matching process has run for the set time,
**Prompt** asks you, and **Stop Now** stops it while **Dismiss** leaves it
running; **Auto Stop** stops it without asking; **Log Only** only records an
event. The **Rules** list turns rules on and off and offers **Edit**,
**Duplicate**, and **Delete**. **Recent Events** shows what happened, and
**Clear** empties it. [Signals each action sends](#signals-each-action-sends)
lists what Prompt and Auto Stop send.

Prompt, Auto Stop, and Log Only rules require current-user ownership and exclude
TaskScope itself and PIDs that cannot be signalled. Auto Stop requires a trusted
kernel executable path, checked again immediately before signaling. Symlinked
rule paths resolve to their targets. Legacy name-only Auto Stop rules load
disabled until reviewed.

A runtime threshold must be reached both by the elapsed time `ps` reports and
by the kernel's monotonic process age, so setting the system clock forward
cannot make a rule act early. The monotonic clock stops during sleep. Sleep
counts only when TaskScope observed it after the process started; sleep before
TaskScope launched can make a rule act later than the displayed elapsed time.
A process whose kernel start time cannot be read is not acted on.

The quick rule sheet shows the executable path or name-wide scope as you edit.
Supplying a path enables a disabled name-only Auto Stop rule, including migrated
legacy rules; the sheet and save message disclose this. Other disabled rules
remain disabled. A quick rule cannot silently overwrite another same-name rule.

Prompt alerts show a PID and are presented anew when the queued target changes.
An unanswered name-only prompt follows a still-matching process when its
executable moves within the same lifetime.
Dismissal survives rule toggles and executable moves for that process occurrence;
changing the rule action to Auto Stop or Log Only allows it to act again.
Rule edits revoke captured pre-signal authority without adding a failure event
for the cancelled automatic stop. Edits that keep Auto Stop enabled and matching
retain the occurrence's handled state and single-retry budget, including after
delivery. A retry waits at least one engine cadence
measured by a monotonic clock. Delivered requests remain in history even if
the rule is later edited, disabled, or deleted. An accepted request is shown as
Stop requested until exit is observed; a changed or unreadable executable path
alone cannot produce an Ended or Stopped event.

Log Only must reach durable event storage before the occurrence is treated as
handled. Event history retains at most 200 records. For mixed or unreadable
stored data and explicit-reset behavior, see [recovery](../SUPPORT.md#stored-data-is-unreadable).

## Saved selections

Select rows, open the **Saved** menu (the bookmark button above the list), and
choose **Save Current Selection…**. Each saved selection appears in that menu
with **Preview & Recall…**, **Rename…**, and **Delete**. Preview & Recall
reloads the process list and shows what it would select before you recall it.

Saved entries use durable kernel executable-path matching and a recall preview.
Legacy entries can fall back to command/name matching and are identified in the
preview; path-backed entries never downgrade to that fallback. Saving refuses
entries without a kernel path. Multiple saved copies of one executable recall
running copies up to the saved count; extra copies require review.

## History, notifications, and hotkeys

The window's header charts (**PROC CPU %** and **PROC RSS**) sum the whole
observed process inventory; the popover does not show them. They have Live,
Paused, and Unavailable states and keep at most 60 samples in memory. Sampling
pauses when no metrics view is visible. Changing the interval schedules the next
sample without an immediate sample burst.

Turn on **Notify on watched process changes** in **Settings > General**, and
choose which presets notify with each preset's switch in **Settings > Watched
Apps**. Notifications require opt-in and system authorization. Editing a
preset's identity, app path, process-name assignments, or notification settings
establishes a new baseline instead of announcing false starts or stops.

Record a different global shortcut in **Settings > Hotkey**. The default
shortcut is ⌃⌥⌘T. Supported saved shortcuts such as Command-Shift-T
are retained. Saved shortcuts rejected by current validation migrate to the
default, with a reason in **Settings > Hotkey** until dismissed or successfully
recorded. Shortcuts require Command or Control; unsupported keys and reserved
macOS shortcuts (including Lock Screen, Full Screen, Emoji & Symbols,
Spaces/Mission Control, and input sources) are refused. Recording errors remain
separate from actual registration/conflict status. See [hotkey recovery](../SUPPORT.md#stored-data-is-unreadable)
for unreadable preferences.

## Behavior reference

Process start evidence uses UTC and names preserve UTF-8. Shared inventory cache
age and ordering use monotonic elapsed time, including sleep; wall-clock changes
cannot extend reuse, and negative ages expire the cache. Destructive checks use
uncached inventory. Open's main-process polling uses a monotonic deadline and an
attempt limit. Shell completion retries child reaping after early exit notifications
and stop requests, including command timeouts.

Commands cancelled while queued or waiting for admission are rejected. Once a
preset Stop acquires the process-operation gate, it completes even if its caller
cancels. Open remains cancellable; readiness waits stop polling and the result
acknowledges possible earlier app or service changes. Cancelled Open and commands
cancelled before execution are not retained as lifecycle failures.

## Stored configuration

Retained rules, presets, selections, and events preserve unknown JSON fields
across saves. Rules with unknown fields are disabled and read-only because a
newer field may narrow their authority. Settings preserve newer values normalized
for display until that setting is changed. This preservation does not implement
newer behavior. Read [Privacy](../PRIVACY.md) before sharing exports or screenshots.
