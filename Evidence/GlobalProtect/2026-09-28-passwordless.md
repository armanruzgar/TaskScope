# Passwordless GlobalProtect session restoration — September 28, 2026

The owner requested removal of the repeated macOS password prompt when opening
GlobalProtect. This follow-up used the same authorized Mac and control methods
as the [earlier live test](2026-09-28-live-stop-restore.md).

## Tested build

- Source: `3c8d40129498787cc7418b51925e424ca1115844`. In the public history,
  the same tree is commit `311cc00ecb01e6ac26821edbad17212d6a613168`
  ([why the SHAs differ](../README.md#commit-shas-in-older-records)).
- TaskScope 1.0.0 (3), `com.local.TaskScope`, installed using
  `script/install.sh`, with the installed signature verified.
- Installed executable SHA-256:
  `256b8e256b7925dc84967e8947d29486fa7a1cb90ae3f4c90cdc78c43d2420dd`.
- macOS 26.6.2 (25G83), arm64; GlobalProtect 6.3.3-1121, with the `pangps`
  login-session service installed.

## Change and setup

The preceding build re-enabled the separate `pangpsd` system service on every
Open, although restoration on this installation used the session `pangps`
service. That unnecessary system mutation caused a macOS administrator prompt
and made the next full stop require another one.

The new build preserves the separate system disable override when the installed
session agent has the expected label. Open restores and verifies the session
service and the user-facing application. Keep Off can then stop the user jobs
and verify the already-disabled system job without changing privileged state.
Toggle-off also preserves that system override and starts no processes.

The previous build had re-enabled the system override before this follow-up.
The owner completed a native administrator prompt once to disable it again.
All three jobs were disabled and unloaded before the new build's Open test.
No credentials were read, entered by the operator, or stored. No helper, sudo
exception, authorization-database change, or vendor-file modification was used.

## Live results

| Action | Observation | Result |
| --- | --- | --- |
| Open from fully disabled state | TaskScope reported successful restoration. Both user jobs were enabled/loaded; GlobalProtect and PanGPS ran. The system job remained disabled/unloaded. No administrator window was observed. | Pass — [Open record](2026-09-28-passwordless/open.json) |
| Connect in GlobalProtect | Client status reached Connected and public HTTPS returned HTTP 200. The system job was still disabled/unloaded. | Pass — [connected state](2026-09-28-passwordless/connected.json) |
| Disconnect in GlobalProtect | Client status became Not Connected; public HTTPS still worked. | Pass |
| Keep Off | Both user jobs became disabled/unloaded. The system job stayed disabled/unloaded. All matching process counts were zero and TaskScope reported off. No administrator window was observed; public HTTPS returned HTTP 200 afterward. | Pass — [stop record](2026-09-28-passwordless/stop.json) |

Native authentication windows were sampled during the Open operation and the
observed stop. During the stop, the confirmation was accepted before the
automation could read it; the operation was already running. The monitor then
observed completion without submitting a second stop. The unchanged system
override and regression tests independently establish that the new session
path avoids an administrator command rather than relying on credential caching.

Final state: GlobalProtect fully off, all three known jobs disabled/unloaded,
public DNS/HTTPS working, and the new TaskScope installed.

## Validation and limits

The complete local gate passed: shell syntax, debug warnings as errors,
458 tests with one opt-in skip and zero failures, coverage, strict concurrency
warnings and actor checks, release build, packaging tests, and diff whitespace
checks. Regression coverage verifies repeated session preparation/stop without
administrator commands, invalid labels failing visibly, and retention of the
administrator path for layouts without the session agent.

This establishes passwordless Open/Keep Off on this tested session layout after
the initial system-disable approval. An external change to the system job or
installed layout may require approval again. It does not cover system-only
installations, pre-login restoration, logout/reboot, management-policy changes,
or private-resource connectivity. The earlier DNS-cleanup limitation remains;
this change does not implement graceful auto-disconnect or network repair.
It is not a qualifying public-release lifecycle manifest.
