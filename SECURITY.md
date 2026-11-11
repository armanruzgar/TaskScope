# Security Policy

## Supported versions

| Version | Security support |
| --- | --- |
| `main` | Security fixes are made here. Active development; not a stable release |
| 1.0.0 | The only published release. It has no maintenance branch and gets no separate fixes; a fix for a problem in 1.0.0 is made on `main` |

1.0.0 is a source release: its GitHub release (tag `v1.0.0`) contains
GitHub-generated source archives and no app binary. A changelog entry or a
local app bundle is not a published release. Say which version or commit you
tested when you report a problem.

## Reporting a vulnerability

Do not open a public issue, discussion, or pull request for a suspected
vulnerability. Do not include exploit details or private process and
organization data in a public channel.

Use the repository's **Security** tab and choose **Report a vulnerability** to
[submit a private report](https://github.com/armanruzgar/TaskScope/security/advisories/new).
Include the affected version/build, macOS version and architecture, impact, and
minimal reproduction steps. Remove usernames, organization details, command
lines, preset paths, and other sensitive data unless essential to the report.

There is no guaranteed response time. Keep reports private while maintainers
investigate and agree on a fix and coordinated disclosure plan.

## Security-sensitive behavior

TaskScope can inspect visible local processes and can signal a selected target
only where macOS permits the current user to do so. A user can also choose a
Force Stop action that sends `SIGKILL`, subject to the same macOS permission
boundary. Only the immutable built-in GlobalProtect definition can request
administrator approval for its fixed `system/com.paloaltonetworks.gp.pangpsd` job:

- Explicit in-app Keep Off / Apply Keep Off, GlobalProtect Quit All, and the
  separately confirmed Stop Services Anyway can disable then boot out the daemon,
  subject to the installed layout's preservation policy.
- Open, turning Keep Off off, and Open Watched App can enable/bootstrap it when
  the layout requires that service; a loaded daemon is never restarted.

These operations use the macOS administrator prompt. Background enforcement and
URLs never request privileges. Custom presets cannot configure privileged jobs;
TaskScope does not bypass authorization. See [GlobalProtect](docs/GLOBALPROTECT.md)
for session-agent preservation, disconnect, timeout, and restoration limits.

Imported watched-app presets are untrusted configuration. Importing a preset
must not execute it, but a later user-approved lifecycle action can use its app
path, user launch-agent plist path and label, and process names. Review every
field before acting. Imports cannot create or modify privileged system-daemon
behavior.

The custom URL scheme accepts refresh only. Destructive preset actions and app
quit are intentionally excluded because another local app or browser can open a
custom URL. Stop Watched App requires system confirmation naming the app,
including direct Siri, Spotlight, and App Shortcut invocation without prior
configuration. Its GlobalProtect scope preserves VPN services. The complete
security model and residual risks are documented in
[THREAT_MODEL.md](THREAT_MODEL.md).
