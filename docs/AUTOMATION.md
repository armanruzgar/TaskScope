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
TaskScope**, **Open Watched App**, and **Stop Watched App**. Open and Stop use a
user-selected entity from stored presets and share the app's lifecycle result
reporting. Stop requests confirmation naming that app before stopping eligible
watched processes, including direct App Shortcut invocation. It runs the same
stop as a custom preset's **Quit All Killable** button, which support
diagnostics record as `close`: it first unloads the preset's user launch agents
(for GlobalProtect only `com.paloaltonetworks.gp.pangpa`), then sends `SIGTERM`
and force stops a process still running three seconds after the stop request.
The confirmation says all of this, names the agents, and warns that apps may
close without asking to save changes.

The App Shortcut phrases are "Refresh TaskScope", "Open *preset* in TaskScope",
and "Stop *preset* in TaskScope", where *preset* is a preset's display name.

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
