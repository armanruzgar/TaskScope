# Automation

## Refresh-only URL contract

The packaged app registers the `taskscope` URL scheme. Another local app,
document, or browser can open a URL, so the sole accepted route is:

```bash
open "taskscope://refresh"
```

It refreshes watched-app status. TaskScope compares the URL with exactly that
string before any normalization, so other spellings, such as
`TASKSCOPE://refresh`, percent-encoded letters, an empty port, or full-width
letters, are rejected. Paths, credentials, ports, query parameters, and
fragments are rejected, as are all other routes, including preset Open, preset
Stop, and application Quit. A cold-launch refresh queues until the command
runtime is ready without requiring a window.

Destructive lifecycle actions require in-app interaction or **Stop Watched App**
with system confirmation. App Shortcuts can be invoked through Siri or Spotlight
without prior configuration; configuration is not the confirmation boundary.
Changes to the URL contract require threat-model review and regression coverage.

## Shortcuts

Install and launch a properly signed packaged app to discover **Refresh
TaskScope**, **Get Watched App Status**, **Open Watched App**, and **Stop
Watched App**. Status, Open and Stop take a preset chosen from the stored
presets; Open and Stop share the app's lifecycle result reporting. Stop requests
confirmation naming that app before stopping eligible
watched processes, including direct App Shortcut invocation. It runs the same
stop as a custom preset's **Quit App and Helpers** button, which support
diagnostics record as `close`: it first unloads the preset's user launch agents
(for GlobalProtect only `com.paloaltonetworks.gp.pangpa`), then sends `SIGTERM`
and force stops a process still running three seconds after the stop request.
The confirmation says all of this, names the agents, and warns that apps may
close without asking to save changes.

**Get Watched App Status** is read-only. It refreshes watched status, as a poll
does, and returns a **Watched App Status** value that a shortcut can test in an
**If** action:

| Property | Value |
| --- | --- |
| Watched App | The preset's display name |
| Status Availability | **Current** after a successful read, **Stale** when the read failed after an earlier one succeeded, **Unknown** when no read has covered the preset |
| Main App Running | Whether the preset's main app is running; empty while the status is Unknown |
| Helpers Running | How many of the preset's helper processes are running; empty while the status is Unknown |
| Keep Off | Whether Keep Off is on for the preset |

A Stale value repeats what TaskScope last observed. The action changes no
process, service, setting, or the status line; its dialog says the same as the
value, for example "GlobalProtect: main app running, 2 helpers running." After a
completed run, **Open Watched App** and **Stop Watched App** return the same
value, read from the inventory TaskScope checked at the end of the action; a
rejected or failed run stops the shortcut with its message instead. No App
Intent turns Keep Off on or off or performs an administrator operation; those
stay explicit in-app actions.

The App Shortcut phrases are "Refresh TaskScope", "Open *preset* in TaskScope",
"Stop *preset* in TaskScope", and "Get *preset* status in TaskScope", where
*preset* is a preset's display name.

Unreadable stored preset data, including wrong-type property-list values,
publishes no default watched-app targets in Shortcuts. A preset that carries
fields from a newer TaskScope build is read-only and is not offered either.

Cold intent launches, including entity pickers and confirmation, stay in the
background without opening a window or leaving a Dock icon. Late intent signals
suppress a launch that has had no interactive activation or explicit window
request; a launch you activated or reopened is never demoted, even during its
first half-second. A cold URL launch stays in the background although Launch
Services activates it before delivering the URL. TaskScope publishes preset
names for its App Shortcuts only after a launch has settled: about half a second
after it starts, or at the first activation of a launch that started inactive.
Queued cancelled commands are
rejected independently. An admitted preset Stop completes despite caller
cancellation; Open readiness remains cancellable and reports possible prior
changes. See [process behavior](USING_TASKSCOPE.md#process-actions-and-observations).

Ad-hoc signing cannot execute App Intents even if metadata verifies. Live
Shortcuts discovery and execution require testing with an eligible signature.

## Administrator operations

Only the immutable built-in GlobalProtect definition has privileged operations:

- Explicit in-app Keep Off / Apply Keep Off, GlobalProtect Quit All, and the
  separately confirmed Stop Services Anyway can disable then boot out the fixed
  `system/com.paloaltonetworks.gp.pangpsd` job, subject to the installed layout.
- Open, turning Keep Off off, and **Open Watched App** can enable/bootstrap that
  fixed daemon when the layout requires it. A loaded daemon is never restarted.

These operations use the macOS administrator prompt. URLs and background
enforcement never request privileges. Shortcuts Stop uses user-process scope:
for GlobalProtect it can unload only `pangpa`, preserving the `pangps` session
VPN service and the system daemon, and its result says when the VPN service is
still running and the VPN was not disconnected. Custom presets cannot introduce
privileged jobs. Read [GlobalProtect](GLOBALPROTECT.md) and the
[threat model](../THREAT_MODEL.md) for attribution, recovery, and layout limits.
