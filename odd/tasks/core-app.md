Objective: a native macOS disk space analyzer, written from scratch in this project. Core features first; the rest in later sessions.
Branch: main. Delivery: exception-ok (greenfield repo, no remote, no PR target). Test runner: `swift test` (DiskCore package, Swift Testing) plus `xcodebuild` for the app.

## Specs

- S1. "Write a new app in this Xcode project with the same look and main features: scanner, sunburst, treemap, file browser, inspector and discard pile."
- S2. Scanner: scan any folder or volume with live progress and cancellation; count allocated size; never count a hard link twice; do not cross into other volumes; record unreadable folders as warnings.
- S3. Sunburst: "Hover over an item to inspect it, then double-click a folder to drill deeper."
- S4. Treemap: same interactions as S3, nested folders with name headers and a hover tooltip.
- S5. File browser: "sortable file browser to inspect items, search the current focus or the entire scan, and filter by item kind or allocated size. Preview files with Quick Look and navigate scans with breadcrumbs and back/forward navigation."
- S6. Inspector: "Detailed inspector with sizes, access information, parent directory, and largest children".
- S7. Discard pile: "Add items from the disk map, file browser, or inspector to the Discard Pile. Review everything together before deciding whether to move anything to the Trash."
- S8. Sidebar and shell (assumption: part of "the same look"): Smart Locations for mounted volumes, Home, Desktop, Documents, Downloads, Library and Applications; recent scans; drag and drop a folder to scan; Reveal in Finder, Copy Path, Move to Trash; Full Disk Access guidance when items are skipped.
- S9. Out of scope for this session, per the chosen option: "Scan comparison, archives, APFS clone detection and localization would come later, over several sessions." Also later (assumption): chart zoom and pan, incremental rescans, exclusions, settings, usage stats, onboarding, Sparkle updates, free-space display, tiny-file summarization.

## Tasks

- T1 [S1] inline: project configuration (macOS only, no sandbox), DiskCore package. Status: done, 2335443.
- T2 [S2] inline: file tree model and parallel scanner with tests. Status: done, cbe905a. RED observed against a stub.
- T3 [S3, S4] inline: sunburst and treemap layout with tests. Status: done, f12c5bd. RED observed at compile time.
- T4 [S5, S7] inline: browser query and discard pile rules with tests. Status: done, ddd287c. RED observed at compile time.
- T5 [S3-S8] inline: SwiftUI shell, charts, browser, inspector, discard pile sheet. Status: done, 48fea0c.
- T6 [S1-S8] delegated: independent verifier (Risk items 1 and 2). Status: running.

## Log

- L1 (2026-10-30, user): asked for a macOS disk space analyzer matching a reference app.
- L2 (2026-10-30, user choice): "Rebuild core from scratch". No source from the reference app is copied.
- L3: A sandbox blocks scanning arbitrary locations, so this app sets ENABLE_APP_SANDBOX = NO.
- L4: Route evidence: every task inline because no Writer trigger reason holds; the units share one model and are not independent.
- L5: Evidence from the running app. `/Applications`: 24622411776 bytes and 277335 files, identical to `du -sk` and `find`, under 5 s in Debug. `~/programming/swiftUI`: identical as well. A temporary self test, not committed, sent real mouse events to the window: hover on both charts, click selection on both charts, double-click drill-in and Back on the sunburst. It also ran search, and a real Move to Trash of a scratch file: the file moved, sizes updated, the scan root was refused.
- L6: Not exercised in the running app: scanning `/` (would raise privacy prompts on the user's screen), unreadable folders outside tests, table row selection and sort clicks, Quick Look, context menus, drag and drop, the sheets, folder double-click on the treemap.
- L7: All browser criteria apply to everything inside the scope. The first draft of the tests filtered kind on direct children only, which contradicted the size filter.
