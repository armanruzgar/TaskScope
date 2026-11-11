# Menu-bar Quit All and failed-connection shutdown

Authorized investigation on September 29 UTC (September 28 local), macOS
26.6.2 (25G83), arm64, GlobalProtect 6.3.3-1121, TaskScope 1.0.0 (3).

The user reported that confirming Quit All in the compact menu-bar window
made the window disappear while GlobalProtect appeared to remain running.
At the first complete state probe, all known jobs were already disabled and
unloaded and all three vendor process counts were zero. That observation
establishes eventual shutdown, not the timing or outcome of every earlier click.

After Open restored the service and one app instance, GlobalProtect reported
Error with Connection Failed and an enabled Connect button. A menu-bar Quit All
on the previous installed binary left both processes running and reported that
it could not verify the connection state. Public HTTPS still worked. Connection
attempts reported that the network connection was unreachable or the portal
unresponsive; this record does not attribute that failure to a particular cause.

## Repair

- Confirming GlobalProtect Quit All or Keep Off in the compact menu opens the
  regular TaskScope window before the vendor UI can take focus. Cancel does not
  open the window or perform a lifecycle operation.
- The Presets footer displays the active step and wraps the complete result.
  Disconnect, stopping services, and final verification have distinct messages.
- The regular window owns the lifecycle result sheet while visible, avoiding
  duplicate sheets in the menu and main window.
- Error is recognized as idle only when the same vendor window contains
  Connection Failed, an enabled Connect control, and no Disconnect control.
  The tooltip is read again after inspecting controls. Five consecutive idle
  observations are still required before changing launch jobs. Ambiguous or
  contradictory states still fail without stopping services.

## Live evidence

The [first failed-connection stop](2026-09-29-menu-quit-all/initial-failed-connection-stop.json)
was confirmed from the 480-point menu window. It showed progress in the new
900-point main window and completed full shutdown in approximately 11 seconds.
All known jobs were disabled/unloaded, all vendor process counts were zero,
public HTTPS returned 200, and no administrator window was observed. This first
build (executable SHA-256
`d5574025fc0e4372693a25beaa9db08b181cd195e5bdfe71e75903f5acf4e485`) exposed
duplicate result sheets; the final refinement gives the regular window sole
ownership and preserves step messages while polling is queued.

Final installed executable SHA-256:
`81e7ae1f7e3e6171b15c588db700fbe9b1fbbf5fbebcebbdd2ea99548446df0b`.

The [final repeat](2026-09-29-menu-quit-all/final-failed-connection-stop.json)
again confirmed Quit All from the compact menu. The main window showed the
Disconnecting and Stopping stages and the final off message. Full shutdown
completed in 8.51 seconds, with zero vendor processes, every known job
unloaded/disabled, one result sheet in the main window and none in the menu,
no administrator window observed, and public HTTPS returning 200.

[Open on the final build](2026-09-29-menu-quit-all/final-open.json) restored
both session jobs and exactly one GlobalProtect UI plus PanGPS, with no
administrator window observed. The vendor still reported Error; service
restoration is not evidence of a successful portal connection.
A [second menu-bar stop](2026-09-29-menu-quit-all/final-restored-stop.json)
then removed all vendor processes and disabled/unloaded every known job in
10.9 seconds, again with one result sheet and public HTTPS 200. GlobalProtect
was left off. Visual inspection of the main window after dismissing the report
confirmed that the complete off message remained readable in the footer.

## Validation and limits

The complete deterministic suite has 476 tests, one opt-in skip, and no failures.
Coverage and strict concurrency/actor-check runs also passed. Warnings-as-errors
debug, release, packaging (including 106 release-evidence cases), shell syntax,
and diff checks passed. New regressions
cover confirmation/cancellation, persistent-window handoff, retained failure
messages, progress text, and ambiguous/contradictory failed-connection controls.

The live case in this record is failed-connection-to-off, not a new
connected-to-off cycle. The latter was exercised by the earlier
[automatic Quit All checks](2026-09-28-quit-all.md). Other versions, translated
UI, managed policies, login/reboot, pre-login, and private-resource connectivity
remain unverified. No VPN configuration, DNS settings, or vendor launch plists
were rewritten. The broader compatibility release gate remains unverified.
