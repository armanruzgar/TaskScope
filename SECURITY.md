# Security Policy

## Supported versions

| Version | Security support |
| --- | --- |
| `main` | Security fixes are made here. Active development; not a stable release |
| 1.1.0 | The latest published release. It has no maintenance branch and gets no separate fixes; a fix for a problem in 1.1.0 is made on `main` |
| 1.0.0 | Superseded by 1.1.0 and not supported |

Both are source releases: their GitHub releases (tags `v1.0.0` and `v1.1.0`)
contain GitHub-generated source archives and no app binary. A changelog entry or a
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

There is no guaranteed response time. TaskScope has a single maintainer; keep
reports private while the maintainer investigates and agrees with you on a fix
and a coordinated disclosure plan.

Dependabot alerts and security updates watch the package's dependencies. The
only one, ViewInspector, is used by the tests and is not built into the app.

## Security-sensitive behavior

TaskScope can inspect visible local processes and can signal a selected target
only where macOS permits the current user to do so. A user can also choose a
Force Stop action that sends `SIGKILL`, subject to the same macOS permission
boundary. Pause (`SIGSTOP`), Resume (`SIGCONT`), and Send Signal (`SIGHUP`,
`SIGINT`, `SIGUSR1`, `SIGUSR2`) reach only the user's own processes, never
TaskScope, GlobalProtect, or a macOS system component, one revalidated PID at a
time; Stop With Children stops each descendant the same way. No action signals a
process group. Only the immutable built-in GlobalProtect definition can request
administrator approval for its fixed `system/com.paloaltonetworks.gp.pangpsd` job:

- The built-in preset's explicit in-app Keep Off / Apply Keep Off, GlobalProtect
  Quit All, and the separately confirmed Stop Services Anyway can disable then
  boot out the daemon,
  subject to the installed layout's preservation policy.
- Open, turning Keep Off off, and Open Watched App can enable/bootstrap it when
  the layout requires that service; a loaded daemon is never restarted.

These operations use the macOS administrator prompt. Background enforcement and
URLs never request privileges. Custom presets cannot configure privileged jobs;
their Keep Off changes only the current user's launchd domain
(`gui/<uid>`), never asks for administrator approval, and signals only the
current user's processes that pass the preset's bundle checks. TaskScope does
not bypass authorization. See [GlobalProtect](docs/GLOBALPROTECT.md)
for session-agent preservation, disconnect, timeout, and restoration limits.

Imported watched-app presets are untrusted configuration. Importing a preset
must not execute it, but a later user-approved lifecycle action can use its app
path, user launch-agent plist path and label, and process names. Turning on a
preset's Keep Off makes TaskScope disable those agents and stop matching
processes whenever they appear, until Keep Off is turned off, so a mistaken
preset is stopped again and again; the confirmation, Dry Run and import preview
say so. Review every field before acting. Imports cannot create or modify privileged system-daemon
behavior. A configuration backup is untrusted in the same way: each part goes
through its own validation, imported Auto-Stop rules arrive turned off until you
review them, because a rule is an authority to stop processes, and a backup
never carries Keep Off, so an import never turns on background enforcement.

The custom URL scheme accepts refresh only. Destructive preset actions and app
quit are intentionally excluded because another local app or browser can open a
custom URL. Stop Watched App requires system confirmation naming the app,
including direct Siri, Spotlight, and App Shortcut invocation without prior
configuration. Its GlobalProtect scope preserves VPN services. Get Watched App
Status only reads and reports status. No App Intent turns Keep Off on or off or
performs an administrator operation. The complete
security model and residual risks are documented in
[THREAT_MODEL.md](THREAT_MODEL.md).
