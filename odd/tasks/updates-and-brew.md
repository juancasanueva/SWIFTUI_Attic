Objective: Sparkle "Check for Updates" and a Homebrew cask for Attic, ported from the release pipeline of the author's battery app.
Branch: feat/updates-and-brew. Delivery: exception-ok (mostly ported files; push, PR, tag and tap push stay the user's decisions). Test runner: `swift test` plus `xcodebuild`.

## Specs

- S1. "I want to implement the "Check for updates" and the brew release like we did for PEriBattery here /Users/juancasanueva/programming/swiftUI/battery"
- S2. In-app updates through Sparkle 2.9.6: a Check for Updates command, an automatic-check preference that stays off until the user turns it on, and when the app last checked, as in the battery app.
- S3. Notarized release built by a tag push through GitHub Actions: archive, export, notarize, staple, verify, smoke, GitHub Release, appcast on GitHub Pages, as in the battery app.
- S4. Homebrew cask `attic` in the existing tap juancasanueva/homebrew-tap, with its bump and CI entries.
- S5. Assumption: bundle identifier becomes com.juancasanueva.attic, following the author's other apps.

## Tasks

- T1 [S2, S5] inline: classic project format with the Sparkle package, Info.plist keys, bundle identifier. Status: done, dc07bbf.
- T2 [S2] inline: update core, Sparkle adapter, menu command, Settings window. Status: done, 82b3e78.
- T3 [S3] inline: release scripts, workflow, RELEASING.md, pipeline tests. Status: done, 8ae8a69.
- T4 [S4] inline: tap cask and workflow entries in a worktree of the tap, not pushed. Status: done locally, tap branch feat/add-attic; sha256 placeholder until the first release.
- T5 [S1-S5] delegated: independent verifier (Risk items 2 and 5). Status: done, no blockers.

## Log

- L1 (2026-10-31, user): "I want to implement the "Check for updates" and the brew release like we did for PEriBattery here /Users/juancasanueva/programming/swiftUI/battery"
- L2: Decision: replace project.xcproj with the classic project.pbxproj. The xcproj format is undocumented, and it read package and build-file shapes without error yet did not link them. It also needs Xcode 27, available on GitHub only as the preview `xcode-27` image, while the classic format builds on the `macos-26` runner the battery app uses. Local Xcode 27 opens it normally.
- L3: Route evidence: every task inline, no Writer trigger reason; the units are a single port.
- L4: Evidence: `swift test` 96 tests pass; shellcheck and actionlint clean; Release build (unsigned, arm64) launched in isolation and stayed up. Not run: signing, notarization, the workflow itself, Xcode 26.6 compile (only Xcode 27.2 is installed locally), Sparkle against a real feed.
- L5: Verifier: no blockers. Port differs from the battery app only in names. Open: Xcode 26.6 compile unproven (Attic is Swift 6 mode, battery Swift 5; a failure stops at archive before anything publishes); no app icon, so releases ship a generic icon. Cheap advisories taken: Sparkle key pinned by test, saved-state zap path, tap README entry, stale comments, placeholder sha documented.
- L6: Native review, granted by the user, lenses risk and resilience: approved with warnings, acknowledged. Open, all inherited unchanged from the battery pipeline: the Sparkle key is first used after Publish and is not checked against SUPublicEDKey, so a wrong key strands the update; the documented recovery of deleting a release and re-running can break a cask sha already bumped; a third queued tag cancels the pending run in the shared concurrency group.
- L7: Rehearsal tag v0.0.1-rc.1 (run 41145771284) passed: Xcode 26.6 compile, Developer ID signing, notarization, staple, verify and smoke all green; prerelease published. Feed steps skipped by design, so the appcast, Pages deploy and Sparkle against a real feed remain unproven until the first stable tag.
