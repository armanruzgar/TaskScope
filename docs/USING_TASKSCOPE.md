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
Processes** or turn on **Auto-refresh process list**, and the count line reads
**Not loaded** until then. With Auto-refresh off, a loaded list is a snapshot:
**Updated** and a time next to the count say when it was read, and the
**Refresh** button in the header reloads it, as do Retry and a saved
selection's **Preview & Recall…**. With Auto-refresh on, the list loads by
itself and reloads at every watched-status read.

**Settings > General** holds these settings:

| Setting | Default | Effect |
| --- | --- | --- |
| Watched status interval | 10 s (2 to 60 s) | How often TaskScope reads watched-app status while a TaskScope window or the menu-bar popover is open; opening one reads at once. With both closed, it reads at this interval only while notifications are on or Keep Off is on for a preset, every 30 seconds (or at this interval when it is longer) while only the menu-bar icon shows status, and not at all otherwise. Keep Off enforcement runs on these reads |
| Auto-refresh process list | Off | Load the process list without **Load Processes** and reload it at every watched-status read |
| Show all processes | Off | List every matching process in any sort order and in tree view; the process list limit then does not apply |
| Process list limit | 80 rows (10 to 200, in steps of 10) | Rows shown while Show all processes is off; a longer result shows **Showing N of M** |
| Highlight Thresholds: CPU % | 30 % | Rows at or above either threshold are highlighted and match the **Hot** filter |
| Highlight Thresholds: Memory (MB) | 1024 MB | See CPU % |
| Show status in the menu-bar icon | On | The menu-bar icon marks TaskScope's state, as described below. While it is on and a preset exists, the icon refreshes every 30 seconds in the background, or at the watched status interval when notifications or Keep Off are on (and when that interval is longer than 30 seconds); turned off, the icon stays plain |
| Notify on watched process changes | Off | Notifications for watched presets; see [notifications](#history-notifications-and-hotkeys) |

With **Show status in the menu-bar icon** on, a mark in the corner of the
menu-bar icon shows what most needs you while the popover is closed:

| Mark | State |
| --- | --- |
| None | Nothing below applies |
| Dot | A watched preset's main app is running |
| Warning triangle | Keep Off is on for a preset, but its service or user agent is running again; use **Apply Keep Off** |
| Question mark | TaskScope could not verify watched status: it is unknown (not read yet) or stale (the last read failed) |
| Bell | An Auto-Stop prompt is waiting in the popover |

When several apply, the bell comes first, then the question mark (stale
snapshots cannot show what is running), then the warning, then the dot.
VoiceOver reads the state with the icon's name, for example "TaskScope, watched
app running". The icon keeps the same size in every state.

The onboarding window opens on interactive launches until you choose **Get
Started**; **Help > Welcome to TaskScope** shows it again. It introduces
watched apps, the menu-bar item and the global shortcut (showing the current
one), stopping processes, customizing, the keyboard, and the Accessibility
access and administrator approval that Quit All and Keep GlobalProtect Off can
ask for; **Settings > Health** shows the Accessibility status.

A quiet launch, such as Launch at Login, a `taskscope://` URL, or a Shortcut,
starts TaskScope in the menu bar without a window. If you then open a
TaskScope window, closing the last one (the main window, About, or the welcome
window) removes the Dock icon again. A launch from the Dock or Finder keeps its
Dock icon.

## Process actions and observations

Type in the search field to match a process name, command, or PID. Text with a
slash, or starting with `~`, also matches the executable path shown under the
name, as shown or in full (`/usr/bin`, `~/dev/`). Search also matches the
command lines of your own processes, ignoring case and across arguments, so
`a.log` finds `tail -f a.log` and `--port 8080` finds the server started with
it. A row found only through its command line shows a magnifying-glass mark,
because the list never shows command lines. TaskScope reads them in memory
while the search field has text, once per refresh, and keeps them only with
that list. Other users' command lines are not searched: macOS shows them only to
`ps`, which would add a process to every refresh. Sort with
the **Sort** menu, which offers CPU, Memory, Name, PID, Parent PID, User,
Network, and Disk, each **Ascending** or **Descending**, or click a column
title: the first click sorts by that column and the next one reverses it. CPU,
memory, network, and disk start highest first, so the display limit keeps the
busiest processes; name, user, PID, and parent PID start in ascending order.
The active column title shows a chevron for its direction, which VoiceOver reads
as sorted ascending or descending. Rows without a value for the sorted column,
such as processes whose network or disk counters macOS does not report, stay at
the end in either direction, and equal values are ordered by name, then PID.
The menu-bar popover has no network or disk columns, so it reads those counters
only while it is open and sorted by one of them. Use the **All / Watched /
Hot** filter and the **Tree view** button. Sort, its direction, search, the
filter, and tree view are saved across launches and shared by the window and
the popover.
Select rows with the circle at the
start of each row; with a selection, the red button with the count offers
**Stop Selected…** and **Force Stop Selected…**, and **Clear** deselects. The
stop button at the end of a row opens the Stop review for that process.
Right-click a row for **Create Auto-Stop Rule…**, **Watch This Process…**,
**Save Selection as Preset…** (when rows are selected), **Stop…**, **Force
Stop…**, **Stop With Children…**, **Pause…** or **Resume**, **Send Signal**,
**Show Detail**, **Copy Executable Path**, **Copy Command Line**,
**Copy Visible Rows**, **Export Visible Rows…**, and **Open in Activity
Monitor**; VoiceOver offers the same actions in its Actions rotor.

**Stop With Children…** stops the process and every process it started, as the
last process list showed them, through the same review as Stop Selected: every
target is listed, and each is checked again (PID, start time, and executable)
right before it is sent `SIGTERM`, one process at a time; a process group is
never signalled. It is offered only for a process that Pause and Send Signal
may reach (below), so never for launchd, TaskScope, GlobalProtect, another
user's process, or a macOS component such as loginwindow, whose children are
your whole session. A descendant that fails those checks is left out together
with everything below it, and the review says how many were left out. It is
also unavailable for a process with no child processes.

**Pause…** sends `SIGSTOP` after a confirmation, and **Resume** sends
`SIGCONT` without one. A paused process stays alive but does not run, and a
paused app does not respond; its row shows a **Paused** badge (the process
state `T`) until it runs again. **Send Signal** offers **Hangup (SIGHUP)…**,
**Interrupt (SIGINT)…**, **User 1 (SIGUSR1)…**, and **User 2 (SIGUSR2)…**,
each confirmed like Stop; what a program does with them is up to the program
(many services reload their configuration on `SIGHUP`, and most programs quit
on `SIGINT`, as on Control-C). Pause, Resume, and Send Signal reach only your
own processes, and never TaskScope, launchd, GlobalProtect, or a macOS system
component (a program under `/System` other than an app in
`/System/Applications`, or under `/usr/libexec`, `/usr/sbin`, `/sbin`, or
`/Library/Apple`): pausing one of those could leave your session
unresponsive. Each signal goes to one process only after TaskScope checks
again that the PID still has the row's identity.

**Copy Visible Rows** copies the rows on screen, with the columns on screen and a
title row, as tab-separated text that a spreadsheet pastes as a table.
**Export Visible Rows…** saves the same rows as a CSV file where you choose.
"On screen" means after search, filter, sort, and the display limit, and in
tree view the rows the tree draws, ancestors included; the menu-bar popover's
columns are name, PID, executable, CPU, and memory, and the window adds parent
PID, user, and the network and disk rates. A value the list shows as a dash is
empty. Neither includes command lines. Text that begins with `=`, `+`, `-`, or
`@`, such as a login shell named `-zsh`, gets a leading `'` so that a
spreadsheet keeps it as text instead of reading a formula.

The process list supports search, sorting, filters, and flat or expandable tree
views. When the display limit truncates results, **Showing N of M** includes
the total matching rows, including search results. In the window, **USER**
shows the account that owns each process, and **NET KB/S** (in / out) and
**DISK MB/S** (read / write) show how fast the process received and sent, or
read and wrote, averaged since the previous refresh. A rate shows a dash until
the second refresh after the window opens, and for processes macOS reports no
counters for. Tree view follows the selected sort at every level,
for the roots and for each parent's children; rows with equal values are
ordered by name, then PID. A parent shown only to place a match in its
hierarchy is dimmed and sorted by its own value, so an idle parent can sit
below busier roots even when one of its children is busy. Tree view opens the
path to every displayed match, including matches that appear later, and the
count line adds how many rows are visible.

Rows hidden by search, filter, or the display limit stay selected until the
process exits or its identity changes; Command-A adds the displayed matching
rows to the selection and keeps those hidden ones. **Stop Selected…** and
**Force Stop Selected…** open a review that lists every captured target with
its name, PID, and path, rows on screen first, and says how many selected rows
are not shown. In the window the review is a sheet; in the menu bar it is an
alert with a scrolling list. A finished batch deselects only its own targets.
Click any tree row, including the selected row or a nested child, to return
keyboard focus for the [list's keys](#keyboard).

The All filter shows processes exposed by macOS. Hot shows rows at or above
either highlight threshold. Watched main processes require current-user
ownership and an executable inside the preset's `Contents/MacOS`; helpers
require current-user ownership and an executable inside `Contents`. Protected
names remain classified across users for display. This display classification
does not authorize a signal or establish a launchd service identity.

Stop sends `SIGTERM`; explicit Force Stop sends `SIGKILL`. An app can quit on
`SIGTERM` without asking to save changes, and the confirmation says so. After a
delivered `SIGTERM`, Stop and Stop Selected wait up to three seconds for the
process to exit before reporting it still running; they never escalate to
`SIGKILL`. Normal process actions never target TaskScope itself, launchd, the
kernel task, or process groups. Captured identities are revalidated
immediately before signals: a single Stop, Force Stop, or Auto Stop checks
them with a basic process read and keeps the Net/Disk readings already shown
for unchanged rows. Missing PIDs, changed identities, and unavailable
verification produce different results. A refused stop says why, for example
"The process is not owned by the current user." or "The system refused the stop
request.", and the Stop Selected report gives the reason for each row.

A changed executable path is not proof that a still-running process exited.
Whether a row has exited comes from the kernel's process state, read with the
process list; an exited (zombie) process is not signalled during manual, batch,
or automatic stops. A process can name itself `<defunct>`, so that text counts
only when the kernel state could not be read, and then only for a row with no
kernel executable path. A missing path alone does not establish exit.

Results go to the footer, and batch results also to a report with a one-line
summary, a line per target, and **Copy Report**; **Done** or Escape closes it,
and a newer report waits until you close the one on screen. A batch's footer
result leads with the stopped count, for example "Stopped 2 of 3 selected; 1
still running.", and lists only parts that are not zero. The footer wraps long
results and announces them to VoiceOver. On the Processes tab it also shows
**Σ shown**, the CPU and memory total of the displayed matching rows. Its
spinner appears only while an action or an explicit refresh runs, not during
background reads, and **Quit** is unavailable while an action runs.

The **Updated** time next to the count changes when the displayed list's
inventory is replaced; it is hidden while Auto-refresh keeps the list current.
In the **Presets** section, the stale watched-status banner appears only when a
watched-status read fails. It shows the last successful watched observation,
with the date for observations before today. Explicit refresh reports its own
result even when joining a silent read. Presets remain visible before the first
watched observation and after read failures; Unknown and Stale status and Retry
distinguish missing evidence from a quiet app.

### Keyboard

Click a row to give the process list keyboard focus. While it has focus:

| Key | Effect |
| --- | --- |
| Up Arrow, Down Arrow | Move the keyboard row |
| Space | Select or deselect the keyboard row |
| Left Arrow, Right Arrow | In tree view, collapse or expand the keyboard row |
| Return | Open the Stop review for the keyboard row (never for TaskScope's own row) |
| Command-I | Show Detail for the keyboard row |
| Escape | Clear the keyboard row; the selection stays |
| Command-A | Add the displayed rows that match the search and filter to the selection; in tree view, only matching rows shown in the tree, not ancestors shown for context. Selected rows hidden by the search or filter stay selected |
| Command-Shift-A | Clear the selection, including selected rows hidden by search or filter |

VoiceOver announces the keyboard row's name and PID as it moves; in tree view,
each row also reports its level.

Elsewhere, the global shortcut (Control-Option-Command-T by default) shows the
TaskScope window, Command-comma opens Settings, and in sheets and dialogs Return
chooses the default button and Escape cancels. Read-only sheets, such as a
lifecycle dry run, the GlobalProtect compatibility check, the diagnostics
preview, and Stop or service results, close with Escape as well as Return.

When the TaskScope window is in front, its menus offer these commands:

| Menu command | Effect |
| --- | --- |
| File > Refresh (Command-R) | Reload the section shown: the process list, or watched status on Presets |
| Edit > Find… (Command-F) | Show **Processes** and put the cursor in the search field |
| Edit > Select All (Command-A) | With the list focused, add the displayed matching rows to the selection |
| View > Tree View | Turn tree view on or off |
| View > Processes, View > Presets | Show that section |
| Process > Show Detail (Command-I) | Show Detail for the keyboard row |
| Process > Copy Visible Rows, Process > Export Visible Rows… | Copy or export the rows and columns on screen |
| Process > Stop…, Process > Force Stop… | Open the review for the selected rows or, with nothing selected, for the keyboard row |
| Help > Welcome to TaskScope (Command-?) | Show the introduction again |

About TaskScope and the welcome window each open as a single window.

### Signals each action sends

| Action | Signals |
| --- | --- |
| Stop, Stop Selected… | One `SIGTERM` per target; TaskScope then waits up to three seconds for the target to exit |
| Force Stop, Force Stop Selected… | One `SIGKILL` per target |
| Stop With Children… | One `SIGTERM` per target, as Stop Selected |
| Pause…, Resume | One `SIGSTOP`, or one `SIGCONT` |
| Send Signal | One `SIGHUP`, `SIGINT`, `SIGUSR1`, or `SIGUSR2` |
| Prompt rule, after **Stop Now** | One `SIGTERM`; never repeated. If the process still runs one 10-second engine cycle later, the event history records a failure that suggests Force Stop |
| Auto Stop rule | `SIGTERM`; if the process still runs at least one 10-second engine cycle later, one more `SIGTERM`. It never sends `SIGKILL`: the event then says to use Force Stop |
| Log Only rule | None |
| Preset Quit App, Quit Helpers, Quit App and Helpers, Restart, and Keep Off; GlobalProtect Quit All | `SIGTERM`, then `SIGKILL` to eligible processes still running after up to three seconds. The main process goes first; all helpers then share one three-second window, so an action waits about six seconds at most |

Preset stops also unload the preset's user launch agents before signalling
(Quit Helpers keeps an agent that runs the main process); see
[watched-app presets](#watched-app-presets).

### Process details and Activity Monitor

A row's context menu offers **Show Detail** (Command-I for the keyboard row),
**Copy Executable Path**, **Copy Command Line**, and **Open in Activity
Monitor**. Show Detail opens a read-only sheet with the name, PID, the parent's
name and PID, the owner's account name, the start time and the time elapsed
since, the kernel's **Executable** path, the `ps` command name, **Command
Line**, the **Code Signature** (signing identifier and Team ID, or Apple, ad
hoc, or Unsigned), **Threads**, **Open Files** (file descriptors, including
sockets and pipes), **Listening Ports** (listening TCP and bound UDP ports),
CPU, and memory. TaskScope reads these from the kernel without starting another
program, between two checks that the PID still has the row's start time; macOS
shows threads, open files, and ports only for your own processes, and any
value it does not give reads **Unavailable** with the reason. A parent that has
exited since is shown by its PID only. Command Line is the process's full
command line, its arguments
separated by spaces as `ps` prints them. It is read only when you open the
sheet, and only while the PID still has the row's start time and executable
path, checked before and after the read; otherwise it reads **Unavailable**
with the reason. Command lines can contain secrets such as tokens, so check the
sheet before sharing a screenshot of it. You can select and copy the sheet's
text; it has no copy button or Activity Monitor control. CPU and memory follow
the process list while the process is listed; otherwise the sheet says they
date from the request. The sheet says when the process is no longer running or
its PID now belongs to a different process, and a failed read offers
**Retry**.

Copy Executable Path copies the process's kernel executable path, or the `ps`
command name when that path is unavailable; it never copies arguments. For a
process started from a shell, the sheet's Command (for example `sleep`) can
therefore differ from what Copy Executable Path copies (`/bin/sleep`).

Copy Command Line reads the command line when you choose it, with the same
checks as the sheet, and copies it only if the PID still belongs to the row's
process. Otherwise nothing is copied and the footer says why, for example that
the PID now belongs to a different process. The footer never shows the command
line itself, and the clipboard entry is marked confidential
(`org.nspasteboard.ConcealedType`) so that clipboard-history tools that honor
that marker do not keep it. TaskScope reads your own processes' command lines
directly from macOS; for other users' processes it runs `ps`, which can read
them.

Open in Activity Monitor requests exact selection of that process.
The row's UTC start time and kernel executable path must match before opening,
on each selection retry, and after selection before success is reported. These
identity checks also support visible root-owned and other-user processes and
executables under `/private/tmp`, `/private/var`, and `/private/etc`. TaskScope
drives only the Activity Monitor in `/System/Applications/Utilities` running its
own executable. For root-owned and other users' processes it searches for the
executable's file name; when no name is known, it clears an existing search so
that the search cannot hide the row. Selection attempts stop about five seconds
after Activity Monitor is open, and an Activity Monitor that stops answering
ends the attempt with "Activity Monitor is not responding."; overlapping
requests run one after another. If Accessibility access is not granted,
Activity Monitor can still open; this status does not imply the user denied a
request.

After a successful selection, TaskScope keeps the search text and View scope
that show the row; a PID column it showed is hidden again about four seconds
later. After an unsuccessful handoff it restores each field it changed, unless
you changed that field yourself. Restoration is best effort and only while the
same Activity Monitor stays open: if Activity Monitor quits within those four
seconds, or TaskScope is force quit, the changes stay, and a relaunched
Activity Monitor is captured afresh.

## Watched-app presets

Add a preset with **Settings > Watched Apps > Add…**, or right-click a running
process and choose **Watch This Process…** (or **Save Selection as Preset…**
for the selected rows). Watch This Process is available only for your own app
processes that run from an app bundle's `Contents/MacOS`; Save Selection as
Preset makes the selected process that is the app bundle's own executable the
main process, even when a helper is listed first. Each preset in Settings >
Watched Apps has a **Notify** switch and **Dry Run** and **Delete…** buttons,
and custom presets also have **Edit…** (unavailable, with the reason, while the
preset is kept off); deleting asks for confirmation.
**Export…** and **Import…** handle the whole list. Each preset card in the
**Presets** section has **Open**, **Quit App**, **Quit Helpers**, **Quit
App and Helpers**, and **Restart**, and a **Keep <name> Off** switch (see
[Keep Off](#keep-off)). **Restart…** quits the app and its helpers as Quit App
and Helpers does, then opens it again, under one confirmation and with one
report of both steps; when the quit does not complete, nothing is opened.
On the built-in GlobalProtect preset, marked with a shield, the
fourth button is **Quit All**, a different and stronger action that disconnects
the VPN and turns on **Keep GlobalProtect Off**, and there is no Restart; read
[GlobalProtect](GLOBALPROTECT.md). Quit
Helpers is unavailable for a preset with no helpers and no user launch agents,
and card actions are unavailable while another action runs. Confirmations name
the preset. If stored presets are unreadable or partly rejected, the Presets
section shows a recovery notice instead of an empty list and says when Keep
GlobalProtect Off is not enforced because the built-in preset is missing from
the list. Keep Off is never enforced for a preset that is not in the list.

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

Quit App stops the main process, Quit Helpers stops the helpers, and Quit App
and Helpers stops both; protected names are excluded. The confirmation, the
dry run, and the result messages use the same name (for example "Quit App and
Helpers did not complete."), support diagnostics record it as `close`, and the
**Stop Watched App** shortcut runs the same stop. On the built-in GlobalProtect
preset, whose fourth button is the stronger **Quit All**, the dry run calls
this stop **Shortcuts Stop**.

Settings supports creation, editing, ordering, import, export, and a lifecycle
dry run. Exports use a versioned archive; legacy array imports remain accepted.
Export writes the presets as stored, including fields that a newer TaskScope
build added. Import is bounded by file size and previews configured fields and
rejection reasons without changing processes; it refuses a preset that carries
a newer build's fields instead of importing it without them. After an import, a
line reports "Imported N presets." and, when some were rejected, how many
validation rejected; an import that adds nothing is shown as an error, and
opening Import again clears the previous outcome. An archive holds
at most 200 presets, and Add and Import stop at 200 (a stored list above 200
still loads). A later user action can use imported app paths, user launch-agent
labels/plist paths, and process names, so inspect untrusted imports. Custom
presets cannot configure privileged system daemons or use GlobalProtect's
launch agents, daemon, or PanGPS process name; the built-in GlobalProtect
privileged definition is immutable.

Helper/protected names and launch-agent labels/paths cannot contain commas.
Names can have at most 255 characters. A launch-agent label must start with an
ASCII letter or digit and contain only ASCII letters, digits, `.`, `-`, `_`,
and `@` (at most 255 characters). No name, path, or label can contain control
characters, invisible formatting characters such as zero-width spaces or
bidirectional overrides, or line or paragraph separators. These rules apply to
the editor, import, and stored presets; a stored preset that breaks them is
handled like other invalid stored data (see
[recovery](../SUPPORT.md#stored-data-is-unreadable)).
Presets must differ in display name and in app path; presets for different
bundles may share a main process name, and notifications then name the preset,
for example "JDownloader2: JavaApplicationStub".
The app path is kept as you entered it. Links in it are followed, in their
on-disk spelling, whenever the preset is matched or opened, so a re-pointed
link or a later install is picked up. When a preset is added, edited, or
imported, a `*.app` link must lead to an app bundle (a folder named `.app` with
`Contents/Info.plist`), and Open checks the bundle again. Main process names
adopt the bundle executable's spelling, and helper lists exclude the main
process. Optional job requirements survive normalization and saves, including
an edit that changes only an agent's label or only its plist path; the editor
cannot make an agent optional.

**Watch This Process** and **Save Selection as Preset** validate every selected
process against the proposed main/helper name, owner, and executable-directory
boundaries before saving. Non-bundled tools receive no fabricated app path.
Extensions and XPC services can be helpers alongside their containing app's main
process, but are not accepted as that main process. TaskScope's own row disables
Watch This Process and Create Auto-Stop Rule.

Open and preset stop actions share lifecycle checks and per-job reporting. Quit
App, Quit Helpers, and Quit App and Helpers verify final inventory against the
definition captured for the action even if the saved preset changes or is
deleted. Preset stops, Keep Off, and GlobalProtect's Quit All stop the main
process first, giving it up to three seconds to exit before force stopping, and
then stop all helpers together in one shared three-second window; confirmations
disclose escalation. Partial reports do not imply every target stopped or that
no signal was sent. When no process was running but a launch agent was
unloaded, the result says so ("launch agents unloaded"). Quit Helpers leaves
loaded, and reports, an agent whose process ID cannot be read.

**Open** restores the preset's required user launch agents, then opens the app
with `/usr/bin/open`. A required agent whose plist is missing stops Open before
anything is launched. An app that is already running is brought to the front by
the same `open`, which reuses the running copy; GlobalProtect is never opened
over its running interface, and Open then reports "GlobalProtect is already
running.". A failed launch shows the reason `open` gave, or the timeout, for
example "Could not open Notes: …". When Open fails after it turned Keep Off off
or restored services, the message says that first, and it never reports a
launch that was not requested.

For GlobalProtect's distinct full-stop and restoration behavior, read
[GlobalProtect](GLOBALPROTECT.md). Ordinary Quit App, Quit Helpers, and Shortcuts
Stop do not disconnect it and leave its VPN services alone.

### Keep Off

Turn on **Keep <name> Off** on a preset's card to keep that app from running,
for example an app whose updater or helper agent keeps relaunching it. After
you confirm, TaskScope persistently disables the preset's user launch agents in
your login session (`launchctl disable gui/<uid>/<label>`, so they do not start
again even at login), unloads any that are loaded, and stops the main process
and helpers with the same checks as Quit App and Helpers. While Keep Off is on,
background enforcement runs at launch and on every watched-status read: when
the app or a helper runs again, TaskScope disables the agents again and stops
the processes. It signals only your own processes that run from inside the
preset's app bundle, never asks for administrator approval, and never changes
system launch daemons. A preset without launch agents is kept off by stopping
it only. **Apply Keep Off…** repeats the whole step at once.

Turning the switch off clears the persistent disable overrides and the Keep Off
intent without opening anything ("Example is allowed to run. Nothing was
started."); **Open** turns Keep Off off too. A mistaken preset would be stopped
on every read, so the confirmation, the **Dry Run** and the import preview say
what Keep Off does for it. While a preset's Keep Off is on, or its Keep Off
action is still running, the preset cannot be edited or deleted (its **Notify**
switch still works): Keep Off acts on the preset as it is, turning it off
re-enables only the launch agents the preset lists then, and an edit would
change what is kept off without a new confirmation. Turn Keep Off off first. The built-in GlobalProtect preset's switch is the
stronger **Keep GlobalProtect Off**, which disconnects the VPN first and can
stop its system service with administrator approval; turning it off opens
GlobalProtect and restores its services. Read [GlobalProtect](GLOBALPROTECT.md).

Deleting the built-in GlobalProtect preset asks for confirmation and says that
its Keep GlobalProtect Off and Disconnect controls go with it. Deletion is
refused while Keep GlobalProtect Off is on, while an explicit Keep Off action
is queued or running, and while settings are unreadable. Any other preset
cannot be edited or deleted while its Keep Off is on, while its explicit Keep
Off action is queued or running, or while settings are unreadable; turn its
Keep Off off first. A relaunch does not recreate a deleted built-in preset. While it is missing and preset storage is
writable, **Settings > Watched Apps > Restore Built-in GlobalProtect Preset**
adds it back; restoring is refused, naming the preset, while a custom preset
uses the same display name or app path, so delete or change that preset first.
Importing an earlier export that contains the built-in preset also restores
the built-in definition.

## Auto-Stop rules

Create a rule under **Add Rule** in **Settings > Auto-Stop**: enter the process
name, an executable path (required for Auto Stop), the rule's conditions, and
the action. A rule acts once all of its conditions hold, and it needs at least
one of run time, CPU, and memory:

- **Runtime minutes**: the process has run at least this long. Type the runtime
  (1 to 1,440 minutes, so at most 24 hours; a value outside that range is
  clamped) or adjust it with the arrows, here, in the Edit Auto-Stop Rule
  sheet, and in the quick rule sheet. Its checkbox turns the condition off; the
  minutes are kept for when you turn it back on.
- **CPU at least** and **Memory at least**, under **More conditions** in the
  Add Rule form and in the Edit Auto-Stop Rule sheet: the process's CPU use (as
  `ps` reports it, where 100% is one full core; 1 to 10,000) or its resident
  memory (1 to 1,048,576 MB) is at or above the value on **Checks in a row**
  engine checks in a row (1 to 360, default 3). The engine checks every 10
  seconds, so 3 checks take about 30 seconds; `ps` reports CPU as a decaying
  average, so one high sample is not enough. A check below the value starts the
  count over, a check sooner than 5 seconds after the last counted one adds
  nothing, and after a gap of more than 30 seconds (sleep, or a process list
  that could not be read) the count starts over. Checks count before a
  run-time floor is reached. Changing the CPU or memory value or the number of
  checks starts the count over; other edits, such as a new action, keep it.
- **Command line contains**, also under **More conditions** and in the Edit
  sheet: text the process's command line must contain. It is plain text, not a
  pattern, compared case-sensitively and kept exactly as typed, spaces included
  (one line, up to 1,000 characters). It narrows which processes the rule is
  about, so a rule still needs run time, CPU, or memory as well. On every check
  TaskScope reads the command line of each of your processes that matches the
  rule's name and path, with the same read Process Detail uses (only while the
  PID still has the listed start time and executable), and keeps only whether
  it contained the text. A command line that cannot be read does not match.
  Command lines are never stored or logged; prompts and history say only that
  the command line contains the rule's text.

You can also right-click a process and choose **Create Auto-Stop Rule…**. That
sheet sets the run time; updating a rule there keeps any CPU and memory
conditions the rule has, and the sheet names them. Once a matching process
meets the rule's conditions, **Prompt** asks you in an alert, even when no
TaskScope window or popover is open; the alert says which conditions the
process met, with its run time, CPU, or memory now.
**Stop Now** stops it, and **Dismiss** leaves it running and stops reminders
for that process until it restarts. **Auto Stop** stops it without asking;
**Log Only** only records an event. Each row of the **Rules** list turns its
rule on and off, shows its conditions and action, and has **Edit…**,
**Duplicate**, and **Delete…** buttons, and a refused change is reported on
that row. **Recent Events** lists every retained event, and **Clear…** empties
it. An event of a rule with a CPU or memory condition has a **Matched:** line
with the conditions the rule acted on. Deleting a rule and clearing events
ask for confirmation first. [Signals each action sends](#signals-each-action-sends)
lists what Prompt and Auto Stop send.

The process name is the name only, for example `node`, never a path. The
executable path must be the executable file itself; for an app that is
`<App>.app/Contents/MacOS/<executable>`, not the `.app` bundle. Add Rule and
Edit refuse a bundle or another directory and suggest the bundle's executable.
A path that does not exist yet is accepted, with an orange note under the rule.
Rules saved before these checks still load and can be switched off or edited.
Each process name can have one rule, compared without regard to case, whatever
the rule's path or action: a second rule for the same name, for another binary
or as an escalation such as Prompt at 30 minutes plus Auto Stop at 120, is not
possible. **Duplicate** adds a switched-off copy named "*name* Copy" (then
"*name* Copy 2", and so on) with the same path, runtime, and action; change its
process name, and its path, before switching it on.

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
When **Update** would move a path-bound rule to the right-clicked process's
executable, the sheet and the result message name the binary the rule covers
now and the one it will cover. Renaming the rule in Update mode drops the old
name's executable path: Prompt and Log Only become name-wide, and Auto Stop is
refused until a path applies. For a process owned by another user or by an
unknown owner, Add and Update are unavailable, with an explanation, because
rules act only on your own processes.

Prompt alerts show a PID and are presented anew when the queued target changes.
An unanswered name-only prompt follows a still-matching process when its
executable moves within the same lifetime; it keeps its place in the queue and
adds nothing to the history.
Dismissal survives rule toggles and executable moves for that process occurrence;
changing the rule action to Auto Stop or Log Only allows it to act again.
Rule edits revoke captured pre-signal authority without adding a failure event
for the cancelled automatic stop. Edits that keep Auto Stop enabled and matching
retain the occurrence's handled state and single-retry budget, including after
delivery. A retry waits at least one engine cadence
measured by a monotonic clock. It belongs to the accepted request, so it does
not wait for CPU or memory conditions to hold again. Delivered requests remain in history even if
the rule is later edited, disabled, or deleted. If an Auto Stop rule is switched
off, deleted, or edited so that it no longer applies while its process is still
exiting, its retry is cancelled and the history records "The rule changed or was
removed before the process exited; its exit will not be tracked." An accepted
request is shown as Stop requested until exit is observed; a changed or
unreadable executable path alone cannot produce an Ended or Stopped event.

TaskScope never repeats a confirmed **Stop Now**. If the process still runs one
engine cadence (10 seconds) after the request was accepted, the history gets
one "Still running after the confirmed stop request. Use Force Stop if it must
exit." failure, and the exit is still recorded when it happens ("Exited after
the stop request."). Saving, editing, switching the rule off and on, or
deleting it, while the request is still running or after it was accepted,
neither prompts again for that process nor loses that exit record.

A Log Only rule logs each process lifetime once, also when the process's
executable is moved or renamed while it runs; a new process on a reused PID is
a new lifetime. Saving, editing, or switching the rule off and on logs a
still-running process again, as does relaunching TaskScope. Log Only must reach
durable event storage before the occurrence is treated as handled.

When a stopped or prompted process exits and its PID is reused before the next
pass, the history says Stopped or Ended; "identity changed" means that the same
process's executable moved. Prompts and Log Only records are not delayed while
an Auto Stop waits for another operation, such as Keep GlobalProtect Off waiting
for administrator approval: each pass handles them first and then runs its
automatic stops. Event history retains at most 200 records and is saved once per
pass. For mixed or unreadable stored data and explicit-reset behavior, see
[recovery](../SUPPORT.md#stored-data-is-unreadable).

## Saved selections

Select rows, open the **Saved** menu (the bookmark button above the list), and
choose **Save Current Selection…**. Each saved selection appears in that menu
with **Preview & Recall…**, **Rename…**, and **Delete…**, which asks for
confirmation. Preview & Recall reloads the process list and shows what it would
select before you recall it; its list scrolls when it has more than 12
entries.

A selection name has at most 100 characters and no line breaks, control
characters, or bidirectional formatting characters; existing names stay as they
are. While saved selections are read-only after a
[recovery](../SUPPORT.md#stored-data-is-unreadable), Preview & Recall still
works, but Rename, Delete, and Save Current Selection are unavailable.

Saved entries use durable kernel executable-path matching and a recall preview.
Legacy entries can fall back to command/name matching and are identified in the
preview; path-backed entries never downgrade to that fallback. Saving refuses
entries without a kernel path. A saved process that is still running, with the
same PID and start time, is selected even when more copies of its executable
run; entries saved before start times were kept match by PID. For an
executable's remaining saved entries, when more unselected copies run than
there are entries, none of them is selected and the preview lists the entries
as ambiguous.

## History, notifications, and hotkeys

The window's header charts sum the whole observed process inventory; the
popover does not show them. **CPU SUM** adds every process's %CPU, where 100% is
one core. **RSS SUM** adds every process's resident memory; memory that
processes share counts once per process, so the sum can exceed the Mac's
memory. Each chart shows its latest value and, below the line, its peak in the
time window; the line is scaled to that peak and placed by time. The window
holds 60 samples at the watched status interval, so the charts cover the last
10 minutes at the default 10 s, and the span is shown beside them. Hover a chart
for how many processes it covers. A failed read, or a pause, starts a new line
segment. The charts say **History paused** or **History unavailable** when
they are not live.

Sampling pauses when no metrics view is visible. Reopening the window shows the
samples still inside the time window, drawn apart from the new ones; older ones
are dropped. While TaskScope polls, the charts reuse each refresh's process read
instead of reading on their own timer, so samples follow the watched status
interval; opening the window takes one sample at once. Changing the interval
schedules the next sample without an immediate sample burst.

Turn on **Notify on watched process changes** in **Settings > General**, and
choose which presets notify with each preset's **Notify** switch in **Settings >
Watched Apps**. Notifications require opt-in and system authorization. Editing a
preset's identity, app path, process-name assignments, or notification settings
establishes a new baseline instead of announcing false starts or stops.

Each refresh sends at most one notification per preset and direction, titled
**Process Started** or **Processes Started** (or **Stopped**) and listing the
names; a newer one replaces the older one for the same preset and direction. A
process name that several presets list appears as "*preset*: *name*". Changes
caused by TaskScope's own Open, Quit, and explicit Keep Off actions are not
announced; those made by background Keep Off enforcement and by auto-stop rules
are. Notifications that arrive while TaskScope is in front also stay in
Notification Center. After you allow notifications in System Settings, delivery
resumes at the next refresh, without reopening TaskScope.

Record a different global shortcut in **Settings > Hotkey**. The default
shortcut is ⌃⌥⌘T. Recording takes keystrokes only from the Settings window:
switching windows, closing Settings, or switching apps cancels it, and the
current hotkey is paused while you record, so pressing it records it.
Supported saved shortcuts such as Command-Shift-T are retained. Shortcuts
require Command or Control. Control-letter combinations such as ⌃C, Command
with an arrow, Delete, Forward Delete, Return, or a digit, and reserved macOS
shortcuts (including Lock Screen, Full Screen, Emoji & Symbols, Spaces/Mission
Control, and input sources) are refused. Saved shortcuts rejected by current
validation migrate to the default, with a reason in **Settings > Hotkey** until
dismissed or successfully recorded. A combination that macOS itself refuses
while you record is reported as "That shortcut is unavailable. The previous
shortcut remains active."; starting a new recording clears an earlier conflict
status. Recording errors remain separate from actual registration/conflict
status. Hotkey preferences with a field of the wrong type enter read-only
recovery like an unreadable value, and the hotkey stays off until reset; see
[hotkey recovery](../SUPPORT.md#stored-data-is-unreadable).

## Behavior reference

Process start evidence uses UTC and names preserve UTF-8. Shared inventory cache
age and ordering use monotonic elapsed time, including sleep; wall-clock changes
cannot extend reuse, and negative ages expire the cache. The age counts from
when a read completed, so a slow read is still shared. A caller that is
cancelled stops waiting at once; a shared read is cancelled only when nobody
waits for it. Destructive checks use uncached inventory. Open's main-process
polling uses a monotonic deadline and an attempt limit. Command completion
retries child reaping after early exit notifications and stop requests,
including command timeouts.

If you quit TaskScope (Command-Q, the Dock, or a logout) while a lifecycle
action runs, TaskScope stops polling and Auto Stop rules and waits up to five
seconds for the action to finish. With no action running it quits at once.
Either way, every command still running, such as `launchctl`, `ps`,
`nettop`, or the administrator `osascript` request, is then stopped as on a
timeout, with a wait of at most about one second, so a stuck action delays quit
or logout by about six seconds at most. An administrator prompt still on screen
is withdrawn, and no new command starts. A Keep Off cut short this way stays
recorded, and background enforcement retries it at the next launch, without
administrator rights. A crash or force quit cannot do any of this.

Commands cancelled while queued or waiting for admission are rejected. Once a
preset Stop acquires the process-operation gate, it completes even if its caller
cancels. Open remains cancellable; readiness waits stop polling and the result
acknowledges possible earlier app or service changes. Cancelled Open and commands
cancelled before execution are not retained as lifecycle failures.

## Configuration backup

**Settings > General > Configuration Backup** saves your configuration to one
file and restores it, for example on another Mac or user account, after
erasing preferences, or before changing the bundle identifier. **Export
Configuration…** writes the watched-app presets, Auto-Stop rules, saved
selections, settings and the hotkey, each as stored, so fields a newer build
added are kept. A backup never holds Keep Off, recovery data or the Auto-Stop
event history. A part whose stored data is in recovery is left out, and a note
says which. Backups use schema version 2 and must stay under 1 MB; at most 200
presets, 500 rules and 500 saved selections import.

**Import Configuration…** reads a configuration backup, a preset archive or a
bare preset array, and shows a preview before anything changes: each part with a
switch to leave it out, every preset field, each Auto-Stop rule's executable
path (or that it matches by name only), action and conditions, each saved
selection's executables, each setting that would change from its current value,
and the hotkey. Each part goes through the same validation as adding it by
hand, and the preview says why an entry is rejected, for example a name already
in use or fields from a newer build. Parts a newer build wrote and this build
does not understand are listed and left out. Importing runs no app, process,
launch agent or privileged operation. **Imported Auto-Stop rules arrive turned
off**: review each one in Settings > Auto-Stop before turning it on. The
settings part never includes Keep Off, so an import never starts background
enforcement. A line then says what was imported and what was not.

**Export…** and **Import…** in Settings > Watched Apps still handle presets
alone. Their export is the preset archive older builds read; their import also
reads a configuration backup but takes only its presets and says that the rest
was left out.

A preset either import adds arrives with Keep Off off, even when Keep Off was
on for it before it was lost, for example in a preset recovery reset or after
an older build deleted it; the presets you have keep their Keep Off. If that
earlier Keep Off disabled the preset's launch agents, they stay disabled until
you turn its Keep Off on and then off again.

## Stored configuration

Retained rules, presets, selections, and events preserve unknown JSON fields
across saves. Rules with unknown fields are disabled and read-only because a
newer field may narrow their authority. For the same reason, a preset that
carries fields from a newer build, in the preset or in one of its launch
agents, is read-only: Settings marks it **Requires a newer build**, it cannot be
edited or deleted, its Open, Quit, and Keep Off actions are refused, Shortcuts
do not offer it, and Import refuses it. The built-in GlobalProtect preset is
exempt because its definition is fixed, and the `priority` key that builds
before 1.0 stored does not count as a newer field. Stored rules that repeat
another rule's ID are rejected when loaded, like rules that repeat a name.
Settings preserve newer values normalized for display until that setting is
changed. This preservation does not implement newer behavior. Read
[Privacy](../PRIVACY.md) before sharing exports or screenshots.
