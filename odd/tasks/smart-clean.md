# Smart Clean

Objective: port FileFinder's Smart Clean (storage overview, nine suggestions, Trash-first with Undo, Empty Trash) to Attic.
Branch: feat/smart-clean. Delivery: exception-ok (mostly ported files; push, PR and release stay the user's decisions). Test runner: `swift test` plus `xcodebuild`.

## Specs

- S1. "I want to implement the Smart Clean funcionality that we did in /Users/juancasanueva/programming/swiftUI/FileFinder"
- S2. Same behavior as FileFinder's `odd/tasks/smart-clean.md` S1–S6 and its shared assumptions: "Space back, safely", "Nine suggestions, each says why, with Undo.", "Everything goes to the Trash first, and Undo brings it back. Empty Trash always asks."
- Assumptions (Attic differences): the trash, undo and Empty Trash parts of FileFinder's `FileActions` become `TrashActions` (Attic has no other file operations). Old downloads still reads the Downloads kind folders FileFinder's Tidy makes. The window opens from the sidebar and File → Smart Clean…, with no shortcut (FileFinder has none by default).

## Tasks

- [x] T1 S1,S2 — Core: catalog, nine scanners, SmartCleanModel, TrashActions, five ported test suites (tests for FileFinder-only copy/move/rename in the Trash dropped; five adapted to Move to Trash) — inline
- [x] T2 S1,S2 — UI: Smart Clean window, sidebar row, File menu item, README — inline

## Log

- L1 2026-11-07 "I want to implement the Smart Clean funcionality that we did in /Users/juancasanueva/programming/swiftUI/FileFinder"
- L2 `swift test`: 218/218 pass. `xcodebuild build` succeeds. Launched the Debug app and opened File → Smart Clean…: storage bar and all nine suggestions filled in on the real Mac (read-only; Clean and Empty Trash not clicked).
