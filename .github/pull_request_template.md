## Summary

Describe the problem and the change.

## Validation

- [ ] `( for f in script/*.sh; do bash -n "$f" || exit 1; done )`
- [ ] `swift build -c debug -Xswiftc -warnings-as-errors`
- [ ] `swift test`
- [ ] `swift test --enable-code-coverage`
- [ ] `swift test --scratch-path .build/strict -Xswiftc -warnings-as-errors -Xswiftc -warn-concurrency -Xswiftc -enable-actor-data-race-checks`
- [ ] `swift build -c release`
- [ ] `./script/test_packaging.sh` (launches the staged app)
- [ ] `git diff --check`

Explain any check that does not apply or could not run.

## Documentation

- [ ] `CHANGELOG.md` [Unreleased] has an entry for every user-visible or
      trust-boundary change in this pull request, or there is none
- [ ] User, privacy, support, and threat-model documents match the changed behavior

## Risk

Call out changes to process signaling, privileged lifecycle operations,
permissions, persistence, packaging, or automation. Write `None` if none apply.
