# Recorded observations

These records are redacted observations from one configuration, retained to
show the tested TaskScope build, environment, actions, results, and limits.
Records that name a source commit identify the tested revision; the others
identify the tested build only by its executable SHA-256.
They are not a compatibility guarantee for another build, macOS release,
GlobalProtect layout, login session, or management policy.

Read the [compatibility matrix](../GLOBALPROTECT_COMPATIBILITY.md) before drawing
conclusions. Read-only snapshots, simulated tests, and authorized lifecycle
checks establish different things. Missing or untested results remain gaps.

The public-binary release gate reads candidate-specific lifecycle manifests and
their referenced records under this directory. Keep the records and their
source bindings intact; do not remove them as generated build output. The
[release guide](../RELEASE.md) describes collection and validation requirements.

## Commit SHAs in older records

The public repository was created on 2026-10-17 from a rewritten copy of the
original development history, so commits made before that date have different
SHAs in the public history. Records written earlier cite the original SHAs.
The tested trees are unchanged; use the public commit with the same tree:

| Cited in a record | Public commit with the same tree |
| --- | --- |
| `059de91` | `1109a3c` |
| `3c8d40129498787cc7418b51925e424ca1115844` | `311cc00ecb01e6ac26821edbad17212d6a613168` |
| `78f2a09129b0d0315107f1698a0720684ec53812` | `272e48714b83bca60de1be2a31a4fbabd5c613e6` |

The public `v1.0.0` tag points to `70be2a5`, which has the same tree as the
originally tagged commit `34625b2`.
