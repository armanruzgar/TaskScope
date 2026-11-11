# Authorized live GlobalProtect stop/restore test — September 28, 2026

The owner explicitly authorized installing TaskScope, controlling the Mac,
disconnecting the VPN, and exercising administrator-protected stop/restore.
Actions used the installed TaskScope interface and native macOS authentication.
The owner completed authentication; credentials were neither read nor entered
by the test operator.

## Environment and artifacts

- macOS 26.6.2 (25G83), arm64; GlobalProtect 6.3.3-1121.
- TaskScope 1.0.0 (3), `com.local.TaskScope`, installed in `/Applications` by
  `script/install.sh`; Apple Development signed, signature verified.
- Final implementation source: `78f2a09129b0d0315107f1698a0720684ec53812`.
  In the public history, the same tree is commit
  `272e48714b83bca60de1be2a31a4fbabd5c613e6`
  ([why the SHAs differ](../README.md#commit-shas-in-older-records)).
- Final installed executable SHA-256:
  `86807067828aaad5f1a985324d3f36f8f304a7434c63646e229d0a0604672770`.
- The earlier full off → Open → Connected cycle used executable SHA-256
  `cae9189e666d2ae364c9950816f823801fbbf405a78441ca4f839989f93a66a1`.
  It had the same lifecycle/inventory fixes; the final build additionally
  included the disconnect-first and DNS-recovery interface guidance.
- Both user launch-agent plists and the system daemon plist were installed.
  The active root PanGPS belonged to `gui/<current-user>/…pangps`, with the
  kernel executable path under the installed GlobalProtect bundle. Root UID
  alone did not identify the system `pangpsd` job.

## Observed results

| Step | Result | Evidence / limits |
| --- | --- | --- |
| Initial Open on the preceding implementation | Failed | It waited for the separate system daemon, which exited on this installation. The session service selection was corrected. |
| Process display | Fixed | Padded `ps` validation timestamps discarded real processes and falsely showed Quiet. After the parser fix, TaskScope showed GlobalProtect and root PanGPS as Active. |
| First stop during VPN use | Partial failure | launchd acknowledged bootout before shutdown completed; TaskScope reported failure too early. A bounded wait fixed this. Native authorization also timed out in unattended attempts; these were reported as failures. |
| Explicit Keep Off with completed administrator authentication | Passed | Both user agents and the system job were disabled and unloaded; GlobalProtect, PanGPA, and PanGPS counts were zero. [State record](2026-09-28-live-stop-restore/fully-off.json). |
| Open from fully disabled state | Passed | Administrator-approved system enable cleared the override. User agents were enabled and loaded; PanGPS and the UI returned. TaskScope verified the session job PID and executable; a separate kernel-path check confirmed root PanGPS under that job. The system job remained unloaded, as expected for this session layout. |
| Connect after Open | Passed with retry | The client initially reported an unreachable network/portal. A Connect retry was made; the client later displayed Connected. Public HTTPS returned HTTP 200. [State record](2026-09-28-live-stop-restore/restored-connected.json). No private application/resource was tested. |
| Normal Disconnect, then stop on the final build | Processes stopped; DNS failed | Despite a Disconnected client observation before stopping, default DNS still referred to VPN servers afterward. Public hostname resolution timed out. This is an unresolved network-cleanup limitation, not a clean pass. |
| Open to recover DNS, without connecting | Passed | The service and UI returned, client status was Not Connected, normal default DNS returned, and public HTTPS succeeded. No DNS or route configuration was manually changed. [Idle baseline](2026-09-28-live-stop-restore/final-idle-baseline.json). |
| Stop the recovered idle service on the final build | Passed | All three known jobs disabled/unloaded, all three process counts zero, public HTTPS returned HTTP 200. [Final off state](2026-09-28-live-stop-restore/final-off.json). |
| Quit and relaunch TaskScope | Passed | A fresh TaskScope PID was verified. Keep Off remained enabled, all known jobs remained disabled/unloaded, no matching processes returned, TaskScope showed Quiet/off, and public HTTPS still succeeded. [After relaunch](2026-09-28-live-stop-restore/after-taskscope-relaunch.json). |
| Logout/login, reboot, policy interference | Not tested | No persistence claim for these events or other management configurations. |

The final Mac state is GlobalProtect fully off with working public DNS/HTTPS.
The VPN application was never uninstalled or reinstalled. All three fixed
vendor launch plists retained their baseline SHA-256 hashes throughout the
test. TaskScope was the only application rebuilt/reinstalled.

## Reproduction and limitations

Disconnect in GlobalProtect before Keep Off. On this build, Disconnect alone
did not always prevent stale DNS after service shutdown. If networking fails,
choose Open and approve the native prompt, leave the VPN disconnected, verify
normal internet access, then retry Keep Off. This recovery was exercised; it
does not guarantee every policy or future VPN version behaves the same way.

The retained JSON snapshots use exact `launchctl print`/`print-disabled`
queries for the three fixed labels and count only executables under the
installed GlobalProtect bundle. Absence requires launchctl's service-not-found
result; other failures are unknown. Snapshots are sequential observations, not
atomic transactions. They omit portal names, accounts, addresses, PIDs, logs,
credentials, and signing-certificate identities. Client status and HTTPS
observations are recorded above separately from process/job snapshots.

The final source passed the repository's complete local gate: shell syntax,
debug warnings as errors, 456 tests (one opt-in test skipped; zero failures),
coverage, concurrency warnings and actor checks, release build, packaging
tests, and diff whitespace checks.

This is development evidence for one installed layout, not a qualifying public
release manifest. Reboot/login persistence, a separately running system daemon,
private-resource connectivity, and managed-policy compatibility remain
unverified. The existing release evidence gate remains in place.
