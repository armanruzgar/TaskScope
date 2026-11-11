# TaskScope Threat Model

This document describes TaskScope's security boundaries and the invariants that
must remain true as the app evolves. It is a design and review aid, not a claim
that a particular artifact is signed, notarized, sandboxed, or vulnerability
free. Update it whenever process actions, lifecycle jobs, automation,
persistence, permissions, or distribution change.

## Scope

In scope:

- local process discovery, display, selection, and signaling;
- auto-stop rules and saved selections;
- watched-app presets, imports, and lifecycle actions;
- custom user launch-agent jobs and the immutable built-in GlobalProtect
  system-daemon stop and restoration paths;
- custom URLs, App Intents/Shortcuts, login items, and notifications;
- preferences, recovery backups, local logs, and preset exports;
- bundle identity, local packaging, signing, installation, and upgrades.

The security of macOS, Xcode, SwiftPM, Apple signing/notarization services,
GlobalProtect, and other managed applications is outside TaskScope's direct
control. TaskScope must nevertheless fail safely when those dependencies are
missing, denied, or return unexpected data.

## Assets and security goals

TaskScope should protect:

- **Process integrity:** signal only the process identity the user reviewed or a
  rule captured, never a recycled PID or a different queued target.
- **System availability:** make destructive actions explicit, keep protected
  processes out of ordinary stop paths, and never target TaskScope itself.
- **Privilege boundaries:** request administrator approval only for visible
  stop or restoration of the fixed daemon in the immutable built-in GlobalProtect
  definition; never let a custom preset add privileged behavior, retain
  credentials, or bypass authorization.
- **Configuration integrity:** validate imported and persisted lifecycle fields,
  preserve unreadable data, and avoid reporting unsaved mutations as durable.
- **Local privacy:** do not transmit process or organization data, and minimize
  its appearance in exports, notifications, and logs.
- **Release integrity:** never represent an ad-hoc or development-signed bundle
  as Developer ID-signed, notarized, universal, or broadly runtime-tested.

## Actors and assumptions

- The interactive macOS user is trusted to approve a clearly described process
  or lifecycle action.
- A preset file, custom URL, process name, process output, local preference, and
  other same-user application are untrusted inputs.
- A same-user local adversary may open a custom URL, alter an exported preset,
  race process exit/PID reuse, or edit preferences. TaskScope should prevent
  those inputs from silently becoming a different destructive action.
- A system administrator controls authorization policy, protected services,
  managed application versions, and writable install locations.
- Malware already running with the user's or administrator's authority is not
  fully contained by this utility; macOS authorization remains the final
  boundary for privileged operations.

## Trust boundaries and required invariants

### Process inventory to signal delivery

TaskScope reads process data through local macOS tools. PIDs are reusable and a
displayed row can become stale at any suspension point.

Required invariants:

- operate only on visible processes and signal only where macOS permits;
- capture a process identity, including start evidence and the kernel-resolved
  executable path when available, before confirmation;
- re-read and compare identity immediately before sending a signal (a basic
  process read without network or disk counters is enough); start-time
  evidence uses UTC to survive time-zone changes. Executable paths remain part
  of equality because start-time evidence has only second precision;
- distinguish “not present,” “identity changed,” and “could not verify”;
  a present PID with changed start or executable evidence is identity-changed;
  a still-running PID/start pair with a moved or unavailable executable path
  must not produce an Auto Stop Ended or Stopped event. Whether a row has
  exited comes from the kernel's zombie state, read with the inventory; an
  exited row must not be signalled. `ps` names come from argv, so a live
  process can call itself `<defunct>`: that text, with no kernel executable
  path, counts as exit only when the kernel state could not be read. A missing
  path alone does not establish exit;
- never turn an unreadable inventory into a success or stale-target claim;
- distinguish unobserved watched status from a verified quiet observation, mark
  retained observations stale after failures, and resolve preset card actions
  against current configuration;
- measure shared inventory cache age and ordering with monotonic time including
  sleep, counting from when a read completed; expire negative ages and use
  uncached inventory for destructive checks. A cancelled caller stops waiting
  at once, and a shared read is cancelled only when no caller waits for it;
- retry shell child reaping after early exit notifications or stop requests
  until reaped, including after command timeout;
- judge preset Quit App, Quit Helpers, and Quit App and Helpers against the
  captured preset and fresh final inventory even if the stored preset changes
  or is deleted;
- partial stop failures must not claim every target stopped or no target
  received a stop request;
- never signal TaskScope itself, launchd (pid 1), the kernel task, or any
  process group other than the one the shell runner creates for its own child
  command; the parser drops such rows and every process-action signal path
  refuses them;
- contain child commands (such as `ps`, `nettop`, `launchctl`, `open`, and the
  administrator `osascript` request) in their own process group: the runner
  spawns each command as the leader of a new group, with `/dev/null` as
  standard input and no other inherited descriptor except standard output and
  error. A command given as an argument vector (so far, the compatibility
  self-check's `launchctl` and `sw_vers` reads) is spawned directly, without a
  shell: its program path must be absolute and is never looked up in `PATH`,
  and an argument containing a NUL character is refused rather than cut short.
  The other commands are still one string run by `/bin/zsh -f -c`.
  Only when a command is cancelled or times out does it send that group
  `SIGTERM`, then `SIGKILL` repeatedly until no member is left, for at most
  750 ms; the result is reported only after that, and a group that could not
  be confirmed empty is reported as such. When TaskScope quits, it first waits
  up to five seconds for a running lifecycle action, then stops every command
  still running the same way, within about one second, and starts no new
  command. If another part of the process collects a command's exit
  status first (`ECHILD`), the command fails and its group is never signalled
  again. This is the one deliberate group signal; it does not pass through the
  process-action signal guard. It reaches only the command's own process tree:
  work handed to another process, such as an approved administrator script,
  is not stopped by a timeout or cancellation;
- start child commands without the inherited variables that change what a
  shell runs (`BASH_ENV`, `ENV`, `SHELLOPTS`, `BASHOPTS`, `PS4`, `CDPATH`,
  `GLOBIGNORE`, `IFS`), exported bash functions (`BASH_FUNC_*`), or `DYLD_*`
  loader variables: `do shell script` hands the `osascript` environment to
  `/bin/sh`, which runs as root for an approved administrator request, and the
  login session's environment can be set by any process of the same user;
- distinguish privileged processes from launchd domains: root ownership alone
  cannot identify the system daemon, because a login-session PanGPS can elevate
  via setuid; readiness, automatic-disconnect gating, final Keep Off
  verification, and the compatibility self-check bind PanGPS to the fixed
  current-user `pangps` or system `pangpsd` job PID and kernel product path,
  and system-daemon readiness also requires a root owner. A complete job
  listing with state but no top-level PID establishes that no service process
  is running; it does not establish that the job is unloaded or disabled.
  Unknown attribution fails without opening the vendor UI or requesting
  Accessibility;
- require a separate, explicit Force Stop confirmation for `SIGKILL`; manual
  Stop never escalates, though it waits up to 3 seconds for the target to exit
  before reporting it still running. Preset quits and Keep Off escalate
  to `SIGKILL` only after a disclosed graceful window (3 seconds) with the
  identity still present: first for the main process, then for all helpers in
  one shared window;
- require current-user ownership and an executable directory for every scoped
  termination; there is no name-only termination entry point;
- bind queued prompts and batch reports to immutable captured targets. Prompt
  alerts show the PID and use a new presentation identity when the queue head
  changes; actions from a retired alert cannot claim the replacement prompt.
- require enabled automatic-stop authority to include a trusted executable path
  and match that path again in the final inventory immediately before signal;
- limit Prompt, Auto Stop, and Log Only candidates to current-user processes,
  excluding TaskScope and unsignalable PIDs;
- wait at least one engine cadence on a monotonic clock before the single
  automatic retry, retaining its budget across edits that remain enabled,
  Auto Stop, and matching. An edit still revokes captured pre-signal authority;
- never downgrade a path-backed saved selection to legacy command/name matching;
- bind Activity Monitor handoff to captured UTC start time and kernel executable
  path using local identity reads that support visible processes regardless of
  owner; verify before opening, every selection retry, and after asynchronous
  selection before reporting success. Missing/changed evidence cannot authorize
  a successful handoff. Drive only the Activity Monitor in
  `/System/Applications/Utilities` running its own executable, never a
  look-alike with the same bundle identifier; bound selection to about five
  seconds, run overlapping handoffs one after another, and restore only fields
  the handoff changed and the user did not.

### Watched presets and imported configuration

A custom preset contains an app path, process names, and optional user
launch-agent labels and plist paths. These values can name real local resources
even though the format does not contain a general-purpose shell command. The
immutable built-in GlobalProtect definition additionally contains fixed
protected-process and system-daemon fields; a custom preset cannot add or alter
them.

Required invariants:

- scope main/helper detection and the Watched filter to the current user, with
  main executables in Contents/MacOS and helpers in Contents, preserving
  protected-service classification across users for display;
- validate every quick-preset process against the resulting main/helper name,
  owner, and executable-directory boundaries before saving;
- importing parses and validates data but performs no lifecycle action;
- bound imported file size and preset count (200), recognize an explicit
  archive schema version, and show every lifecycle field plus rejection reason
  before import is committed;
- keep a custom app path as entered and resolve links in it whenever the preset
  is matched or opened; require a `*.app` link to lead to an app bundle when a
  preset is added, edited, or imported, and check the bundle again before Open;
- require absolute `.app` and `.plist` paths, non-empty names of at most 255
  characters, and launch-agent labels that start with an ASCII letter or digit
  and contain only ASCII letters, digits, `.`, `-`, `_`, and `@`, so a label
  cannot retarget `launchctl`; reject control, invisible formatting, and line or
  paragraph separator characters in every name, path, and label, so a reviewed
  field cannot read differently from its bytes. Lifecycle actions and
  diagnostics also skip any job whose label breaks these rules;
- reject duplicate identities (a display name or an app path that another
  preset uses), invalid mappings, and any privileged daemon fields on a
  noncanonical preset; reject custom presets that name GlobalProtect's launch
  agent or daemon labels, their plist paths, or the PanGPS process name;
- require the built-in GlobalProtect identity and all of its privileged fields
  to match the fixed canonical definition exactly;
- present custom configured fields for review before destructive use;
- construct fixed tool invocations without evaluating a preset value as shell
  source;
- treat the built-in GlobalProtect preset as version-specific configuration,
  not authority to alter arbitrary protected processes;
- keep protected process names out of the normal killable-name set.

Keep Off polling is triggered only by current-user main/helper processes.
Preserved PanGPS services, including non-root session instances, do not trigger
enforcement or count as failed background session stops. Startup enforcement
disables both fixed user jobs, unloads only `pangpa`, and preserves `pangps`.
Within one run, unchanged background failures do not republish reports, replace
status messages, or duplicate diagnostics. For three minutes after an explicit
disconnect fails and asks the user to answer GlobalProtect's own request, or
until the next explicit action, background enforcement leaves the vendor UI
alone. PanGPS is never signalled directly.

Residual risk: a syntactically valid custom preset can intentionally point at
the wrong local app or user launch agent. The mandatory import preview exposes
those fields but cannot decide whether the user intended them, so users must
still trust and inspect the source. This risk cannot create a custom privileged
system-daemon operation, and a custom preset cannot point at GlobalProtect's
launch agents, daemon, or PanGPS.

### Privileged GlobalProtect service control

Only the immutable built-in GlobalProtect identity can disable/unload, enable,
or bootstrap the fixed system `pangpsd` daemon with macOS administrator
approval. Custom presets cannot configure this path. Explicit Keep Off and the
built-in preset's Quit All disconnect an active VPN before stopping services;
their confirmation discloses the persistent stop and restoration path.

Required invariants:

- only explicit in-app Keep Off / Apply Keep Off, GlobalProtect Quit All, or the
  separately confirmed Stop Services Anyway recovery may request a system stop;
  background enforcement and startup may verify system state but never prompt
  or mutate it. Open, toggle-off, and Open Watched App may request fixed system
  enable/bootstrap when the installed layout requires it;
- automatic disconnect uses Accessibility only for the fixed GlobalProtect
  executable, rechecking its kernel path before inspection/actions. Only the
  normal Disconnect control is pressed; credentials and management challenges
  are never filled. The vendor app is brought forward to reveal its controls;
  a lost popover gets bounded retries. Unknown state, denial, timeout, or a
  failed press aborts the normal attempt before writing new Keep Off intent or
  changing launch jobs. AX reads run on a
  bounded worker queue. Five consecutive disconnected observations precede
  shutdown; Connected, busy, or unavailable resets the streak. Up to 60
  observations with 0.5-second waits give about 30 seconds of observation time
  plus reads, inside a 90-second overall deadline that also bounds AX requests;
  timeouts leave services running.
  An Error tooltip counts as disconnected only with the same vendor window's
  Connection Failed text, enabled Connect control, and no Disconnect control;
  Error alone, contradictory controls, and unreadable state still abort;
- after a failed explicit disconnect, **Stop Services Anyway** offers a separate
  in-app confirmation that discloses interruption and stale VPN DNS risk, with
  Open as the recovery path. It uses the same fixed service operations and
  administrator authorization, but skips the connection-state prerequisite.
  The recovery is bound to the current failure by a one-use in-memory ID,
  checked inside the mutation gate. Retry and Open (including toggle-off)
  invalidate older failures. No URL, Shortcut, background tick, or stored preference
  can authorize this exception;
- validate the complete built-in identity and fixed job fields before privileged
  commands; require the installed matching plist before introducing a disable
  override so the restore path remains available. With no daemon plist and
  launchd confirming that no daemon is loaded, Keep Off has nothing to disable
  and writes no override;
- name TaskScope, the GlobalProtect system VPN service, and the requested
  change in every administrator prompt; report a cancelled, denied, or timed-out
  request as such, and after a timeout let launchd's state decide the result;
- disable before bootout so launchd cannot immediately respawn the service;
- check both the disabled override and absence of the loaded job after stopping;
  after a successful administrator stop, allow up to 30 seconds for shutdown,
  with probe timeouts bounded by the remaining deadline. Denied, cancelled,
  timed-out, or unknown reads cannot establish success;
- enable before bootstrap; Open restores the installed session `pangps` job
  before its UI, checking the launchd PID, current-user/root ownership, and a
  fresh kernel executable path in the fixed product directories; only layouts
  without this agent use the system daemon path;
- do not force-restart a newly bootstrapped user job with `kickstart -k`, or
  directly signal PanGPS. A loaded service is left running; a loaded but idle
  session job, with no running process, is started once with a plain
  `kickstart`, which never restarts a running job;
- when a valid installed session agent supplies the VPN service, Open and
  toggle-off preserve an existing disable override on the separate system
  daemon. This avoids privilege requests by avoiding the unnecessary system
  mutation; it installs no helper, stores no credentials, and changes no
  authorization policy. On session layouts, Keep Off changes the system override
  only after verifying the daemon is unloaded; a loaded or unknown daemon is
  preserved and reported as an incomplete stop. Missing session agents retain
  the administrator path;
- turning Keep Off off uses the same full restoration command as Open;
- Open restarts an orphaned GlobalProtect UI only when a fresh inventory shows
  that UI running without any PanGPS service. Recovery unloads only the fixed
  `pangpa` UI job and verifies the old UI is gone before restoration. It never
  unloads `pangps` or the system daemon to recover a window. A healthy running
  service and UI are preserved;
- before bootstrapping an unloaded `pangpa` job, check a fresh inventory and
  current-user ownership plus kernel executable path for a directly opened
  GlobalProtect UI. Preserve that UI instead of starting a duplicate; unknown
  inventory fails without launching;
- report cancellation and partial failures, retaining requested intent until
  user-agent restoration succeeds; show a running system service instead of an
  off badge. Polling cancellation skips background reports and failure retention;
- bound service readiness by a monotonic 15-second deadline, including probe
  time and inventory reads, and cap each command timeout by remaining time;
- escape command arguments, retain no credentials, and never remove, rename,
  or rewrite vendor files;
- changes to the fixed system job use launchd, never arbitrary elevated process
  signaling or custom/imported system commands.

Residual risk: macOS authorization elevates the fixed commands, and changing a
VPN service may affect network availability. Vendor files remain controlled by
the installer/system administrator. Management software can reject or undo a
change; report this instead of bypassing policy. VPN connectivity and system
extensions are outside the process/launchd checks and require live validation.

### Persistent GlobalProtect suppression

Keep Off stores intent in TaskScope and disabled overrides in launchd's user and
system databases. Existing user-only intent does not authorize privileged
background operations after upgrade; Apply Keep Off requests the expanded
operation explicitly. Open and toggle-off are the explicit restoration paths.

Background enforcement persistently disables both fixed current-user jobs but
unloads only `pangpa`. Any loaded `pangps` is preserved because polling does not
verify a disconnected tunnel. It re-checks intent inside the operation gate so queued
enforcement cannot undo Open. It never repeatedly prompts for system approval
or automatically fights a system service restored by management. Automatic
disconnect UI control runs only during an explicit action, never polling. The UI shows
that service running and offers a confirmed explicit action; a loaded separate
system daemon on a session layout remains preserved even on retry. No destructive
URL route is added; ordinary process stop and Auto Stop retain their existing boundaries.

### URL, Shortcut, and login automation

Any local app, webpage handler, or document can attempt to open a custom URL.
App Intents can be invoked through user-configured Shortcuts or directly through
Siri, Spotlight, and App Shortcuts without prior configuration.

Required invariants:

- accept only the exact string `taskscope://refresh` through the custom URL
  scheme, compared before URL normalization, so case, percent-encoding, an
  empty port, or full-width letters cannot pass;
- reject URL requests to open/stop presets or quit TaskScope;
- queue a cold-launch refresh without activating unnecessary UI;
- discard cancelled queued commands before dispatch and carry cancellation into
  a command waiting for the process-operation gate; cancelling one submission
  must not cancel its neighbors or imply that completed mutations were undone;
- finish an admitted preset Stop despite caller cancellation; keep Open readiness
  cancellable and report possible prior changes without retaining cancellation
  as an inventory or lifecycle failure;
- route App Intent actions through the same identity validation and truthful
  result reporting as the app; Stop Watched App must request system confirmation
  naming the app, the user launch agents it unloads, `SIGTERM`, and the force
  stop after three seconds before submitting a stop command, including direct
  App Shortcuts;
- keep cold intent launches in the background, including entity queries and
  confirmation; late intent signals suppress a launch with no interactive
  activation or explicit window request, and never demote a launch the user
  activated or reopened, including during the launch grace period. A URL keeps a
  starting launch in the background even though Launch Services activates a
  cold URL launch before delivering the URL. TaskScope's own App Shortcuts
  parameter refresh waits until the launch has settled, so the entity query it
  triggers cannot reclassify a Dock or Finder launch;
- do not treat local/development signing as proof of production artifact
  identity;
- make Launch at Login optional and recover visibly from macOS approval states;
  provide an explicit unregister action in Requires Approval and Unavailable
  states and report removal errors.

### Preferences, exports, and recovery

Settings > Health has a separate read-only probe surface with no lifecycle,
permission-request, registration, or preference writer. It checks local signing
integrity with network access disabled, size- and time-bounded (10-second)
regular-file metadata read
through symlink targets with descriptor type checks and nonblocking opens, and
running/on-disk identity without reporting signature integrity as notarization,
distribution trust, or Shortcuts execution. Unknown access remains unverified;
inaccessible files do not become missing files. Optional paths and corrupt-store
fallbacks retain their distinct meaning. Expired observations and canceled
collections cannot authorize recovery. Recovery only navigates to verified local
destinations, rechecks the target on click, and never silently resets TCC,
registers login items, reinstalls/re-signs an app, or executes a Shortcut.
Results stay in memory and do not extend the support export schema.

Support diagnostics are a separate export boundary from preset backups. The
report model accepts fixed status/action/reason categories, booleans, counts,
timestamps, and strictly numeric version metadata. Schema version 2 encodes
unreadable saved Keep Off and notification settings as `null`, never default or
unsaved in-memory booleans. Lifecycle entry points record `open`,
`quitApp`, `quitHelpers`, `close`, or `keepOff`; automatic disconnect failure
uses `disconnectFailed`. Toggle-off maps to `open`, GlobalProtect Quit All and
Stop Services Anyway to `keepOff`, and Shortcuts Stop to `close`.
It never serializes raw presets, command results, inventory, logs, or error strings. Custom preset UUIDs
are used only for in-memory filtering and replaced with a report-local reference;
only a verified built-in identity receives the fixed GlobalProtect kind.
Lifecycle failure retention is bounded to 20 session entries and raw job data is
reduced to counts at capture. Collection performs read-only permission/file/job
checks without administrator prompts or lifecycle mutation. The entire JSON is
previewed before explicit copy/save, using the same immutable byte buffer.
Tests exercise adversarial names, commands, paths, errors, metadata, identity
spoofing, retention, and equality of preview/file contents. This does not redact
ordinary lifecycle sheets, preset exports, picker screenshots, or local logs.

Standard preferences store settings, preset/rule data, saved process matching
fields, event history, and recovery backups. They are local but not encrypted
or protected from the current user.

Required invariants:

- detect an existing same-user, same-bundle instance before shared-store writes,
  command handling, hotkey registration, or background enforcement; request a
  reopen of its window and terminate the duplicate. The running instance holds
  an exclusive, close-on-exec `flock` on
  `~/Library/Application Support/<bundle id>/Instance.lock` and lets it go while
  quitting, once its settings are saved and no action is running; the kernel
  drops it on a crash. A launch hands off only to the holder its lock record
  names (same PID, start time, user, and bundle identifier), never to a holder
  marked quitting, which it waits for up to ten seconds; only when the lock
  cannot decide does it hand off to an instance that started earlier. Startup
  verification never takes the lock;
- isolate startup-verification stores and onboarding in fresh volatile defaults
  without reading/changing normal preferences or enforcing Keep Off; a
  startup-verification instance rejects every command at once and quits by
  itself after 60 seconds;
- decode versioned data defensively; recover valid events individually, preserve
  mixed payloads in rejectedMigrationBackup slots, and require explicit reset
  before committing recovered events or resuming durable logging;
- preserve unknown stored JSON fields and non-string event outcomes on retained
  entries, including automatic preset normalization and event trimming;
- disable and lock rules with unknown fields rather than enforce a rule whose
  newer restrictions are not understood; likewise keep a preset whose fields,
  or whose launch agents' fields, come from a newer build read-only, refuse its
  lifecycle actions and its import, and omit it from Shortcuts. Only the
  built-in GlobalProtect preset, whose definition is fixed, and the retired
  `priority` key are exempt;
- treat a payload whose known fields decode but that holds a value this build
  cannot write back as read-only, and back it up like an unreadable payload;
  back up and stop writing over settings that something outside TaskScope
  replaced with an unreadable payload while it runs;
- reject stored rules that repeat another rule's ID or name, and saved
  selections that repeat an ID, into `.rejectedMigrationBackup` recovery;
- keep normalized settings fallbacks in memory without replacing newer stored
  values during unrelated saves;
- preserve unreadable payloads instead of overwriting them with defaults,
  including binary property-list backups of wrong-type values and non-dictionary
  hotkey settings. Keep primary values read-only until explicit reset;
- publish no default App Intents watched-app targets when stored preset data is
  unreadable, including wrong-type property-list values;
- retain original partially rejected presets/rules/selections/events in
  `.rejectedMigrationBackup` slots alongside unreadable `.corruptBackup` slots;
  each family has ten non-overwriting slots (base suffix, `.2` through `.10);
- recover valid saved selections independently, preserve their unknown fields,
  and require explicit reset to commit recovered entries;
- block persistence that would silently destroy unreadable primary data;
- refuse all Keep Off intent writers while settings are unreadable, including
  GlobalProtect Quit All and confirmed Stop Services Anyway; show the saved
  intent as unknown and pause background Keep Off enforcement until reset;
- refuse built-in preset deletion when settings recovery makes Keep Off unknown,
  Keep Off is enabled, or an explicit action is queued/running; recheck preset
  existence and settings writability after disconnect before writing intent
  or disabling services. Restoring a deleted built-in preset adds only the
  fixed canonical definition and is refused while a custom preset holds its
  display name or app path;
- label a recovery reset as "after backup" only while a recovery slot holds the
  unreadable payload; otherwise say that it is discarded and ask first;
- preserve optional launch-job requirements through normalization and migration
  so valid built-in presets round-trip without entering corruption recovery;
- require an explicit destructive reset to resume writes;
- never export a fallback empty collection as if it were a valid backup;
- keep auto-stop history bounded and live chart samples in memory;
- document that changing the bundle identifier changes the preference domain
  and requires a tested migration or an explicit data-loss warning.

### Logs, notifications, and reports

Process and preset names can identify a person, organization, or sensitive
application even when they never leave the Mac.

Required invariants:

- no analytics or automatic diagnostic upload;
- do not log monitored processes' command lines or imported lifecycle payloads.
  A command line appears only in the Process Detail sheet the user opens or on
  the clipboard after Copy Command Line: it is read on request, only while the
  PID still has the row's start time and executable path (checked before and
  after the read), and never stored, logged, or included in diagnostics,
  reports, exports, or notifications;
- record every signal TaskScope sends, and every launchd change, app open, and
  administrator request it runs, in the Unified Log's `Actions` category with
  the outcome, so its actions can be reconstructed after it quits; signal,
  PID, and exit status are public, process names and TaskScope's own command
  lines private;
- use private log interpolation unless a field is demonstrably nonsensitive;
- notify only after opt-in and avoid false transitions during reconfiguration;
  re-baseline when preset identities, app paths, process-name assignments, or
  notification settings change, and after TaskScope's own Open, Quit, and
  explicit Keep Off actions, which are not announced;
- tell users to sanitize screenshots, logs, exports, and bug reports.

### Build and distribution

The local build/install scripts create a same-machine bundle using an Apple
Development identity when available or ad-hoc signing otherwise, always with
the hardened runtime. They build the current architecture and do not notarize.
The separate credential-gated release pipeline can produce a Developer
ID-signed, hardened, arm64, notarized artifact, but only when its real Apple
credentials and automated checks succeed.

Required invariants:

- keep bundle identifier, version, build, architecture, and signature claims
  consistent with the artifact;
- sign every build with the hardened runtime, which stops
  `DYLD_INSERT_LIBRARIES` injection into a bundle that may hold Accessibility
  trust; only an explicit `--debug` build adds `get-task-allow`. Remove
  build-machine run paths before signing and reject non-system run paths and
  `@rpath` libraries;
- verify the bundle after copying and installation, including identifier,
  version, and build;
- hold the packaging lock throughout static/startup verification and through
  validation and copying for installation; record each lock's owner and break
  a lock only when its recorded process ID now belongs to another process;
- check for running same-identifier bundles before opening or debugging another
  path; refuse known conflicts without stopping that other copy, before
  building or replacing anything;
- refuse to replace an install destination that is a file, a symbolic link, or
  another app;
- replace an installed bundle transactionally and restore it on failure; recover
  a transaction interrupted outright before the next stage or install changes
  anything;
- build release artifacts only from the default branch at its pushed upstream,
  refuse a version whose tag exists, and strip distributed binaries only after
  extracting their dSYM;
- keep public history and release tags fixed: repository rulesets block
  force-pushes to and deletion of `main`, and moving or deleting `v*` tags;
- keep Dependabot alerts and security updates on for the package's
  dependencies, and merge a dependency update only after its CI checks and the
  full local gate pass;
- do not publish a local staged app as a production binary;
- require Developer ID signing, hardened runtime review, notarization, stapling,
  checksums, and clean-machine verification before claiming a public binary;
- treat a production bundle-ID change as a data/permission migration event.

Residual risk: the hardened runtime does not protect a bundle in a
user-writable location, such as a staged copy in a checkout or an install in a
user-owned folder, from being modified or replaced by another process of the
same user. Signature checks and **Settings > Health** can reveal a changed
bundle but cannot prevent the change. The Health signature row reports whether
an intact signature has the hardened runtime; `codesign -dv` shows it as well.

## Abuse cases and expected response

| Abuse case | Expected response |
| --- | --- |
| Browser opens `taskscope://stop/...` | Reject without a process action. |
| PID exits and is reused after confirmation | Identity revalidation prevents the signal and reports the changed target. |
| Process changes executable after confirmation | Executable-path identity revalidation prevents the signal. |
| Process inventory fails | Report verification failure; do not claim stopped or stale. |
| Imported custom preset contains a relative plist path or any system-daemon job | Reject that preset without executing it. |
| Custom preset names GlobalProtect's launch agents, daemon, or PanGPS | Reject the preset; only the built-in definition controls GlobalProtect. |
| Preset or rule carries fields from a newer build | Keep it read-only and disable such a rule; refuse such a preset's actions and its import instead of dropping the fields. |
| Valid-looking custom preset points at an unintended user launch agent | Show the field and later-operation summary before import; require the user to reject an unintended path. |
| Preferences contain malformed JSON or a wrong property-list type | Preserve backup, enter read-only recovery state, require explicit reset. |
| A same-user process holds the instance lock file or rewrites its record | Hand off only to a listed same-user, same-bundle TaskScope with the recorded start time; after about half a second without one (ten seconds for a holder marked quitting), use the earlier-start rule. |
| Privileged bootstrap fails or is denied | Report failure and leave the managed files intact. |
| Ad-hoc bundle is presented as a production binary | Release gate rejects the claim and artifact. |

## Security review checklist

For every release and trust-boundary change:

1. Add a regression test that fails before the security fix.
2. Run the complete gate in [RELEASE.md](RELEASE.md).
3. Exercise signals only against disposable controlled processes.
4. Test missing, malformed, denied, partial-failure, cancellation, and PID-reuse
   paths.
5. Inspect imported-data handling and every shell/AppleScript argument boundary.
6. Review logs, notifications, exports, and public error text for private data.
7. Verify actual artifact architecture and signing/notarization state.
8. Update this document, [PRIVACY.md](PRIVACY.md), and the changelog.

Vulnerabilities should be reported according to [SECURITY.md](SECURITY.md).
