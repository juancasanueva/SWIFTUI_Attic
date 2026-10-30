Objective: Sparkle "Check for Updates" and a Homebrew cask for Attic, ported from the release pipeline of the author's battery app.
Branch: feat/updates-and-brew. Delivery: exception-ok (mostly ported files; push, PR, tag and tap push stay the user's decisions). Test runner: `swift test` plus `xcodebuild`.

## Specs

- S1. "I want to implement the "Check for updates" and the brew release like we did for PEriBattery here /Users/juancasanueva/programming/swiftUI/battery"
- S2. In-app updates through Sparkle 2.9.6: a Check for Updates command, an automatic-check preference that stays off until the user turns it on, and when the app last checked, as in the battery app.
- S3. Notarized release built by a tag push through GitHub Actions: archive, export, notarize, staple, verify, smoke, GitHub Release, appcast on GitHub Pages, as in the battery app.
- S4. Homebrew cask `attic` in the existing tap juancasanueva/homebrew-tap, with its bump and CI entries.
- S5. Assumption: bundle identifier becomes com.juancasanueva.attic, following the author's other apps.

## Tasks

- T1 [S2, S5] inline: classic project format with the Sparkle package, Info.plist keys, bundle identifier. Status: pending.
- T2 [S2] inline: update core, Sparkle adapter, menu command, Settings window. Status: pending.
- T3 [S3] inline: release scripts, workflow, RELEASING.md, pipeline tests. Status: pending.
- T4 [S4] inline: tap cask and workflow entries in a worktree of the tap, not pushed. Status: pending.
- T5 [S1-S5] delegated: independent verifier (Risk items 2 and 5). Status: pending.

## Log

- L1 (2026-10-31, user): "I want to implement the "Check for updates" and the brew release like we did for PEriBattery here /Users/juancasanueva/programming/swiftUI/battery"
- L2: Decision: replace project.xcproj with the classic project.pbxproj. The xcproj format is undocumented, and it read package and build-file shapes without error yet did not link them. It also needs Xcode 27, available on GitHub only as the preview `xcode-27` image, while the classic format builds on the `macos-26` runner the battery app uses. Local Xcode 27 opens it normally.
- L3: Route evidence: every task inline, no Writer trigger reason; the units are a single port.
