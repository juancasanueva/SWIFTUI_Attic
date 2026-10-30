Objective: a native macOS disk space analyzer, written from scratch in this project. Core features first; the rest in later sessions.
Branch: main. Delivery: exception-ok (greenfield repo, no remote, no PR target). Test runner: `swift test` (DiskCore package, Swift Testing) plus `xcodebuild` for the app.

## Specs

- S1. "Write a new app in this Xcode project with the same look and main features: scanner, sunburst, treemap, file browser, inspector and discard pile."
- S2. Scanner: scan any folder or volume with live progress and cancellation; count allocated size; never count a hard link twice; do not cross into other volumes; record unreadable folders as warnings.
- S3. Sunburst: "Hover over an item to inspect it, then double-click a folder to drill deeper."
- S4. Treemap: same interactions as S3, nested folders with name headers and a hover tooltip.
- S5. File browser: "sortable file browser to inspect items, search the current focus or the entire scan, and filter by item kind or allocated size. Preview files with Quick Look and navigate scans with breadcrumbs and back/forward navigation."
- S6. Inspector: "Detailed inspector with sizes, access information, parent directory, and largest children".
- S7. Move to Trash: confirmed by the user; system locations and the scanned location are refused. The Discard Pile is removed, see L14.
- S8. Sidebar and shell (assumption: part of "the same look"): Smart Locations for mounted volumes, Home, Desktop, Documents, Downloads, Library and Applications; recent scans; drag and drop a folder to scan; Reveal in Finder, Copy Path, Move to Trash; Full Disk Access guidance when items are skipped.
- S9. Out of scope for this session, per the chosen option: "Scan comparison, archives, APFS clone detection and localization would come later, over several sessions." Also later (assumption): chart zoom and pan, incremental rescans, exclusions, settings, usage stats, onboarding, Sparkle updates, free-space display, tiny-file summarization.

## Tasks

- T1 [S1] inline: project configuration (macOS only, no sandbox), DiskCore package. Status: done, 2335443.
- T2 [S2] inline: file tree model and parallel scanner with tests. Status: done, cbe905a. RED observed against a stub.
- T3 [S3, S4] inline: sunburst and treemap layout with tests. Status: done, f12c5bd. RED observed at compile time.
- T4 [S5, S7] inline: browser query and discard pile rules with tests. Status: done, ddd287c. RED observed at compile time.
- T5 [S3-S8] inline: SwiftUI shell, charts, browser, inspector, discard pile sheet. Status: done, 48fea0c.
- T6 [S1-S8] delegated: independent verifier (Risk items 1 and 2). Status: done. Recheck: B1, B2, B4 fixed; B3 variant fixed by a second correction (506a5cf), pinned by a regression test.

## Log

- L1 (2026-10-30, user): asked for a macOS disk space analyzer matching a reference app. The name is left out at the user's request, see L17.
- L2 (2026-10-30, user choice): "Rebuild core from scratch". No source from the reference app is copied.
- L3: A sandbox blocks scanning arbitrary locations, so this app sets ENABLE_APP_SANDBOX = NO.
- L4: Route evidence: every task inline because no Writer trigger reason holds; the units share one model and are not independent.
- L5: Evidence from the running app. `/Applications`: 24622411776 bytes and 277335 files, identical to `du -sk` and `find`, under 5 s in Debug. `~/programming/swiftUI`: identical as well. A temporary self test, not committed, sent real mouse events to the window: hover on both charts, click selection on both charts, double-click drill-in and Back on the sunburst. It also ran search, and a real Move to Trash of a scratch file: the file moved, sizes updated, the scan root was refused.
- L6: Not exercised in the running app: scanning `/` (would raise privacy prompts on the user's screen), unreadable folders outside tests, table row selection and sort clicks, Quick Look, context menus, drag and drop, the sheets, folder double-click on the treemap.
- L7: All browser criteria apply to everything inside the scope. The first draft of the tests filtered kind on direct children only, which contradicted the size filter.
- L8: Verifier first pass, baseline 36a66f2. Blockers: B1 scanner entered volumes mounted inside the scan, because a mount point reports the device of the file system underneath it. B2 review list hid items inside a refused folder that were then moved. B3 safety policy compared raw strings, so symlinked and case-variant paths passed. B4 a rescan left `pendingTrash` holding IDs from the old tree, which could trash a different file. S3-S6 passed by code.
- L9: Correction: B1 requests ATTR_DIR_MOUNTSTATUS (verified on `/`: firmlinks report 0, `/dev` reports 1) and excludes the virtual `/.vol`, `/.nofollow` and `/.resolve`. B2 adds TrashPlan, the single source for both the review sheet and the move. B3 canonicalizes with F_GETPATH and compares case-insensitively. B4 clears `pendingTrash` when a scan starts; this lives in the app target, which has no test target, so it has no regression test. Also taken: A1 and A2 (more protected paths), A4 (failure report kept when a scan raced the move), A6 (Quick Look works with the browser hidden), A8 (rescan matches by path), and the confirmation moved inside the sheet.
- L10: Advisories left open: A3 trashing the hard link that carried the size reports it as reclaimed; A5 Kind column sorts by category rather than the label shown, results capped at 20,000 silently; A7 paths over PATH_MAX become warnings, a folder swapped for a symlink mid-scan would be followed.
- L11: Native review of 36a66f2..506a5cf, granted by the user, lenses risk and reliability: approved with warnings only, acknowledged. Taken in a follow-up: stale browser rows and sunburst layout after cancellation, trash requests lost while a move runs, logical size of hard links, sort indicator after the view is recreated.
- L12: Open from that review: an entry-level ATTR_CMN_ERROR is discarded, so such an entry can look like an empty special file with no warning. With hard links across folders, which folder carries the size depends on worker timing, although the total is stable. WorkspaceModel rules, including the B4 fix, have no automated test because the app target has no test target.
- L13 (2026-10-30, user): "can we make it as MacOS15 minimum?" Deployment target changed from 27.2 to 15.0.
- L14 (2026-10-30, user): "I dont like the Discard Pile functionality. Remove it". Decision: the pile, its sheet, chart marks and footer are removed; Move to Trash stays, with its safety policy and confirmation, because the user did not ask to lose it. TrashPlan keeps the same rules and is now built from the chosen items. L10 and L12 references to the pile no longer apply.
- L15: Verifier on the removal: Trash rules identical to HEAD (2,304 probe cases). One blocker, the protected-paths test was lost when splitting the test file; restored. The confirmation dialog now states the plan, since the review sheet that showed it is gone.
- L16 (2026-10-31, user): "use Attic". The app is named Attic through PRODUCT_NAME. Project, target, scheme, repository folder and the DiskCore package keep their names. Name availability not checked.
- L17 (2026-10-31, user): the reference app is not to be named anywhere.
