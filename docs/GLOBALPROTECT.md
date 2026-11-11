# GlobalProtect behavior and recovery

TaskScope's built-in preset targets fixed GlobalProtect processes and launchd
jobs. Product layouts and management policies vary. The [compatibility matrix](../GLOBALPROTECT_COMPATIBILITY.md)
records limited observations; lifecycle behavior across login/reboot and
management policies remains unverified.

## Quit All and explicit Keep Off

**Quit All**, the **Keep GlobalProtect Off** switch, and **Apply Keep Off…** use
the full shutdown path after confirmation. TaskScope attributes PanGPS to the
fixed current-user `pangps` or system `pangpsd` launchd job using the job PID,
ownership, and kernel executable path. Root ownership alone is insufficient:
a session service can run as root through setuid. A complete job listing with
state but no top-level PID establishes that no service process is running, not
that the job is unloaded or disabled. Malformed output remains unknown; unknown
attribution fails before opening the vendor UI or requesting Accessibility.

When needed, TaskScope requests Accessibility to press the fixed vendor app's
Disconnect control and waits for five consecutive disconnected observations.
A Connected, busy, or unreadable observation resets that streak. The current
adapter recognizes English status/control labels. **Not Connected** is idle;
**Error** is idle only with **Connection Failed**, an enabled **Connect**, and
no **Disconnect** in the same vendor window. Error alone is insufficient.
TaskScope never enters credentials or answers policy challenges.

The observation window is about 30 seconds: up to 60 observations with waits of
0.5 seconds between them, plus observation work. A 90-second overall deadline
also bounds Accessibility requests. Opening or revealing controls and slow
reads can consume that deadline; unreadable state can fail sooner. A timeout,
unavailable control, permission failure, or unverifiable disconnect leaves
services running without recording new Keep Off intent or changing launch jobs.

After verified disconnect, TaskScope records Keep Off intent, persistently
disables the known per-user jobs, unloads them, and stops eligible app/helper
processes. The fixed system `pangpsd` daemon can be disabled then booted out
with macOS administrator approval. The macOS prompt names TaskScope, the
GlobalProtect system VPN service and its label, and the change: stopping and
disabling it here, re-enabling or starting it for Open. After successful
authorization, shutdown verification allows up to 30 seconds with bounded
probes. Unknown reads and partial failures are reported, never treated as proof
of an off state. Once the privileged script reports that its disable step
succeeded, that verification decides the result, not bootout's exit status.
Cancelled or denied approval and a failed disable are reported in plain words
after one inspection, without waiting. A timed-out administrator request is
reported as timed out, and launchd's state then decides whether the change
happened.

On session-agent installations, a loaded or uninspectable separate system
daemon and its override are preserved and the stop is incomplete. Retrying
Apply Keep Off does not override that policy. Consult the organization managing
the Mac. Only an already-unloaded system daemon can receive the disable override
on that layout, with a matching installed plist and administrator approval.
When no system daemon plist is installed and launchd confirms that no system
daemon is loaded, there is nothing to disable: Keep Off completes without an
override and without an administrator request. PanGPS is never signalled
directly, and vendor files and VPN configuration are never removed or
rewritten.

A full stop from the menu bar opens the regular TaskScope window before vendor
UI control; progress and the complete result remain visible. The result window
returns to the front after success or failure.

## Failed disconnect recovery

After a failed explicit disconnect, **Stop Services Anyway…** offers a separate
confirmation. It skips the idle-state prerequisite and uses the same fixed
service operations and administrator authorization. It can interrupt internet
access or leave stale VPN DNS. The exception is tied to a one-use, in-memory
failure identifier; a new attempt, Open, or app restart clears it. URLs,
Shortcuts, background ticks, and stored preferences cannot authorize it.

When a failed disconnect asks you to complete GlobalProtect's own request,
background enforcement leaves GlobalProtect's interface open for up to three
minutes, or until your next explicit action (a retry, Stop Services Anyway, or
Open), so that you can answer it.

If DNS fails after stopping, choose **Open**, leave the VPN disconnected, and
verify normal internet access before retrying Keep Off. Earlier observations on
GlobalProtect 6.3.3-1121 found stale DNS even after the client displayed
Disconnected; Open restored DNS without reconnecting, and a subsequent idle stop
preserved public DNS/HTTPS. Later [automatic Quit All observations](../Evidence/GlobalProtect/2026-09-28-quit-all.md)
recorded two connected-to-off cycles on the recorded configuration, with public
HTTPS working after the second. These results are not a guarantee. TaskScope
does not rewrite DNS, routes, or vendor settings as a workaround.

## Open and turning Keep Off off

Both actions perform full restoration of the required VPN service and app.
Open clears required disable overrides even without saved Keep Off intent; if
the app bundle is missing, it attempts override recovery and reports that
nothing could be opened. Failed user-job restoration retains Keep Off intent.

When a valid `pangps` session agent is installed, Open restores and verifies it
before opening the app. If that job is loaded but idle, with no running
process, Open starts it once with a plain `launchctl kickstart`; when PanGPS
still cannot be verified, the result says to choose Quit All, then Open. A
failed start request for a job that is already loaded is a warning, not a
failure. Without a session agent, Open enables/bootstraps the fixed system
daemon with administrator approval, after checking that the installed plist's
label matches; the daemon counts as ready only when launchd's PID belongs to a
root-owned PanGPS in a known GlobalProtect product directory. Open never
restarts a loaded daemon or force-restarts a newly bootstrapped user job.
Healthy unchanged Open reports no restoration and shows no service sheet.
Malformed or mismatched session plists fail visibly.

Session installations preserve the separate system daemon's disable override.
After the initial approved full stop, subsequent cycles need no administrator
prompt unless system state or the installed layout changes. TaskScope stores
no password, installs no elevated helper, and makes no authorization exception.
This retained override needs explicit cleanup during [uninstall](../SUPPORT.md#uninstall-and-erase-local-data).

If the UI is stuck retrieving portal configuration without PanGPS, Open closes
that orphaned UI, verifies it is gone, restores the service, and starts one UI.
It does not unload a VPN service to recover a window or bootstrap a duplicate
interface over an existing healthy one. Use the organization/IT installer or
support path if the protected service cannot be restored.

## Ordinary Quit and background enforcement

Quit App, Quit Helpers, and Shortcuts Stop do not disconnect. For GlobalProtect,
they can unload only the `pangpa` interface agent, preserving the `pangps`
session VPN service and system daemon. Quit Helpers also preserves an agent
running the main process. Their results say when the VPN service (PanGPS) is
still running and the VPN was not disconnected, and point to Quit All. Stopping
a session VPN service under a connected tunnel can leave DNS unusable, so use
the full explicit path when intended.

Background Keep Off runs at startup and when current-user main/helper processes
return. It disables both fixed user jobs but unloads only `pangpa`, preserving
a loaded `pangps`. A preserved PanGPS service is not a polling trigger or a
failed background session stop. Background checks never request administrator
approval or change system services. Service state and Apply Keep Off remain
visible; within one run of TaskScope, unchanged failures do not repeatedly
replace the footer, publish reports, or append diagnostics, so each launch
reports a still-failing background check once. User-job and system-state
failures can produce reports. Older saved intent never authorizes a background
privileged stop.

## Settings recovery and preset deletion

Unreadable settings disable Quit All, Apply Keep Off, the Keep Off switch, and
Stop Services Anyway with a reset-settings explanation. The saved Keep Off
intent is part of the unreadable data, so the card shows Keep GlobalProtect
Off as Unknown and background Keep Off enforcement is paused. Preserve the
recovery backup and use **Settings > General > Reset Settings After Backup**
(or **Discard Unreadable Settings and Reset** when no backup slot was free)
before changing Keep Off; after the reset, Keep Off is off until you turn it on
again. Quit App and Quit Helpers remain available.

Deleting the built-in preset asks for confirmation and says that its Keep
GlobalProtect Off and Disconnect controls go with it. It cannot be deleted
while Keep Off is enabled, an explicit Keep Off action is queued or running, or
settings are unreadable. The action rechecks preset existence and settings
writability after disconnect before recording intent or changing services;
stale confirmations cannot orphan overrides. **Settings > Watched Apps >
Restore Built-in GlobalProtect Preset**, shown while the preset is missing and
preset storage is writable, adds it back, unless a custom preset uses the same
display name or app path.

## Compatibility and support

**Compatibility Self-Check** reads known installation, launchd, and process
state without changing lifecycle state. Preview, copy, or export the redacted
summary. See [collection instructions](../SUPPORT.md#collect-globalprotect-compatibility-evidence)
and [compatibility evidence](../GLOBALPROTECT_COMPATIBILITY.md).

An off result concerns known processes and launchd jobs. It does not verify VPN
health, remove system extensions, certify policy compatibility, or discover
relocated jobs. Fast User Switching and vendor UI routing between sessions
still require live validation. Management can reject or reverse changes;
TaskScope reports failure and does not bypass policy.
