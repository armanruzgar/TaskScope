## Summary

Describe the problem and the change.

## Validation

CI runs the script syntax check, the debug build, `swift test`, the strict
step, and the compiler-warning check on this pull request. It does not run code
coverage, the release build, or the packaging test, so check each step below
that you ran locally.

- [ ] `( for f in script/*.sh; do bash -n "$f" || exit 1; done )`
- [ ] `swift build -c debug -Xswiftc -warnings-as-errors`
- [ ] `swift test`
- [ ] `swift test --enable-code-coverage`
- [ ] `swift test --scratch-path .build/strict -Xswiftc -warnings-as-errors -Xswiftc -warn-concurrency -Xswiftc -enable-actor-data-race-checks`
- [ ] No compiler warnings: the clean `.build/warnings` build and its `grep` step from CONTRIBUTING.md print nothing
- [ ] `swift build -c release`
- [ ] `./script/test_packaging.sh` (launches test copies of the app)
- [ ] `git diff --check`

Explain any check that does not apply or could not run.

## Documentation

- [ ] `CHANGELOG.md` [Unreleased] has an entry for every user-visible or
      trust-boundary change in this pull request, or there is none
- [ ] User, privacy, support, and threat-model documents match the changed behavior

## Risk

Call out changes to process signaling, privileged lifecycle operations,
permissions, persistence, packaging, or automation. Write `None` if none apply.
