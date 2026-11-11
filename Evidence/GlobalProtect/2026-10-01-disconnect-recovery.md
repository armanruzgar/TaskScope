# Visible GlobalProtect shutdown and disconnect recovery

October 1, 2026, on the existing arm64 Mac with GlobalProtect 6.3.3-1121
and TaskScope 1.0.0 (3). The user reported a menu-bar action disappearing and
a normal-window disconnect timeout that left services running.

The [old installed build](2026-10-01-disconnect-recovery/menu-before.json)
also failed to inspect the vendor's Error/Connection Failed view when its
popover was lost during the window handoff. Both vendor processes and both
session jobs remained running. A subsequent connected-to-off action on that
old binary succeeded; the original timeout is intermittent and is not claimed
as deterministically reproduced here.

## Changes

- Activate the fixed vendor UI before opening its status panel, reacquire the
  panel on subsequent observations, and tolerate two consecutive unreadable
  observations. Unknown readings reset the stable-idle counter and never
  authorize a normal shutdown. Disabled Disconnect controls are not pressed.
- Bring the regular TaskScope window forward again after success or failure,
  including actions originating in the menu bar.
- A failed explicit disconnect exposes **Stop Services Anyway…** on the preset.
  Its separate confirmation explains interruption/stale-DNS risk and the Open
  recovery path. It stops/disables the same fixed launch jobs with the existing
  macOS authorization. It does not require Accessibility to work afterward.
- Bind that recovery to a one-use in-memory failure ID validated inside the
  mutation gate. New attempts, Open, and allow-to-run invalidate older failures;
  background actions and external automation do not gain this exception.

## Installed-build live check

Executable SHA-256:
`2b7c5d689d4617f17e59522a05370f8a75d49f12873c5d0b5e2efe8cf20a0edf`.

The [controlled recovery](2026-10-01-disconnect-recovery/menu-recovery.json)
began with Not Connected. The verified vendor UI process alone was temporarily
suspended to simulate an unresponsive Accessibility server. Keep Off was
confirmed from the 480-point menu. The normal attempt failed after 7.38 seconds
with both session jobs/processes preserved and the 900-point main window in
front showing the failure. The UI process was resumed before recovery.

Cancel in the recovery confirmation left the services running. The harness
labels both the cancel and the confirm step "Confirmed recovery choice"; the
cancel step is evidenced by the `after_cancel` state, recorded about 1.1
seconds after the failure, with both session jobs still loaded and the process
counts unchanged. A second click
and confirmation stopped all vendor processes and disabled/unloaded all three
known jobs in 5.77 seconds. The main result window was frontmost and had one
report sheet. Public HTTPS returned 200; vendor launch files were unchanged.
The harness always resumed the verified UI process on exit, including setup
attempts interrupted by AX focus/sheet timing before this completed run.

A subsequent Open restored one UI and one VPN service. The
[normal menu-bar Quit All](2026-10-01-disconnect-recovery/normal-stop.json)
then stopped the idle VPN in 8.73 seconds, with one main-window report sheet,
all jobs disabled/unloaded, zero vendor processes, and public HTTPS 200.
GlobalProtect was left off on the installed build.

## Automated validation and limits

482 tests, one opt-in skip, zero failures in the normal, coverage, and strict
concurrency/actor-check suites. Warnings-as-errors debug, release, shell syntax,
packaging (including 106 compatibility-evidence cases), and diff checks passed.
Regression tests cover lost-panel retries and stable-idle reset, rejection of
stale/unrequested/consumed recovery IDs, Open invalidation, the separate
confirmation and cancellation, and returning focus to the result.

The controlled case tests an unresponsive UI with an initially idle VPN, not
an active tunnel's network cleanup or a managed policy challenge. No credentials,
VPN configuration, DNS configuration, or vendor launch files were edited.
This is not evidence of fixing stale VPN DNS, other versions/languages,
login/reboot behavior, system-only installations, or management policies.
