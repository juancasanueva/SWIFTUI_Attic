import AppKit
import Foundation
import Testing
@testable import DiskCore

/// A scanner that returns fixed candidates, for testing the model.
struct FixedScanner: SuggestionScanner {
    let kind: SuggestionKind
    let candidates: @Sendable (CleanEnvironment) -> [CleanCandidate]

    func scan(_ environment: CleanEnvironment) async throws -> [CleanCandidate] { candidates(environment) }
}

@MainActor
@Suite("Smart Clean")
struct SmartCleanTests {
    let dir: TemporaryDirectory
    let undoManager: UndoManager
    let actions: TrashActions

    init() throws {
        dir = try TemporaryDirectory()
        try dir.folder(".Trash")
        undoManager = UndoManager()
        undoManager.groupsByEvent = false
        actions = TrashActions.withTestTrash(
            dir.url.appending(path: ".Trash"))
        actions.undoManager = undoManager
    }

    private func environment() -> CleanEnvironment {
        CleanEnvironment.testing(home: dir.url)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.url.appending(path: path).path)
    }

    private func model(_ scanners: [any SuggestionScanner]) -> SmartCleanModel {
        let home = dir.url
        return SmartCleanModel(
            actions: actions, scanners: scanners, environment: { CleanEnvironment.testing(home: home) },
            measureStorage: false)
    }

    // MARK: - Catalog

    @Test("Nine suggestions: four Safe to clear (ticked), five Your call (unticked), each with a why")
    func catalog() {
        #expect(SuggestionKind.allCases.count == 9)
        #expect(SuggestionKind.allCases.filter { $0.group == .safe } == [.developerCaches, .duplicates, .installers, .mailAttachments])
        #expect(SuggestionKind.allCases.filter { $0.group == .yourCall } == [.bigFiles, .unusedApps, .screenRecordings, .oldDownloads, .leftovers])
        #expect(SuggestionKind.allCases.allSatisfy { !$0.title.isEmpty && !$0.why.isEmpty })
        #expect(CleanGroup.safe.title == "Safe to clear" && CleanGroup.yourCall.title == "Your call")
    }

    // MARK: - Scanning and ticks

    @Test("Safe to clear starts ticked, Your call unticked, and a candidate can opt out (node_modules)")
    func defaultTicks() async throws {
        let cache = try dir.file("cache.bin", bytes: 10)
        let modules = try dir.folder("app/node_modules")
        let big = try dir.file("big.mov", bytes: 30)
        let model = model([
            FixedScanner(kind: .developerCaches) { _ in [
                CleanCandidate(url: cache, bytes: 10, detail: "cache"),
                CleanCandidate(url: modules, bytes: 5, detail: "untouched", isTickedByDefault: false),
            ] },
            FixedScanner(kind: .bigFiles) { _ in [CleanCandidate(url: big, bytes: 30, detail: "big")] },
        ])

        await model.lookAgain()

        #expect(model.suggestions.map(\.kind) == SuggestionKind.allCases)
        #expect(model.ticked == [cache.canonical])
        #expect(model.tickedBytes == 10)
        #expect(model.suggestion(.bigFiles)?.bytes == 30)
        #expect(model.suggestion(.duplicates)?.candidates.isEmpty == true)
    }

    @Test("An item listed by two suggestions counts once; ticking it ticks it everywhere")
    func overlap() async throws {
        let file = try dir.file("Downloads/old.dmg", bytes: 7)
        let model = model([
            FixedScanner(kind: .installers) { _ in [CleanCandidate(url: file, bytes: 7, detail: "a")] },
            FixedScanner(kind: .oldDownloads) { _ in [CleanCandidate(url: file, bytes: 7, detail: "b")] },
        ])
        await model.lookAgain()

        #expect(model.tickedBytes == 7)
        model.toggle(file)
        #expect(model.ticked.isEmpty)
        model.setAll(.oldDownloads, ticked: true)
        #expect(model.ticked == [file.canonical])
    }

    // MARK: - Cleaning

    @Test("Clean moves only the ticked items to the Trash, as one step Undo brings back")
    func cleanAndUndo() async throws {
        let a = try dir.file("a.bin", bytes: 1)
        let b = try dir.file("b.bin", bytes: 1)
        let keep = try dir.file("keep.bin", bytes: 1)
        let model = model([
            FixedScanner(kind: .developerCaches) { _ in [
                CleanCandidate(url: a, bytes: 1, detail: ""), CleanCandidate(url: b, bytes: 1, detail: ""),
            ] },
            FixedScanner(kind: .bigFiles) { _ in [CleanCandidate(url: keep, bytes: 1, detail: "")] },
        ])
        await model.lookAgain()

        await model.clean()

        #expect(!exists("a.bin") && !exists("b.bin") && exists("keep.bin"))
        #expect(undoManager.undoActionName == "Smart Clean")
        #expect(model.ticked.isEmpty)
        #expect(model.suggestion(.developerCaches)?.candidates.isEmpty == true)   // looked again

        undoManager.undo()
        await actions.waitForPendingWork()
        #expect(exists("a.bin") && exists("b.bin"))
        #expect(!undoManager.canUndo)
    }

    @Test("A ticked item inside a ticked folder isn't trashed twice")
    func nestedTicks() async throws {
        let folder = try dir.folder("DerivedData")
        let inner = try dir.file("DerivedData/App/build.o", bytes: 1)
        let model = model([
            FixedScanner(kind: .developerCaches) { _ in [CleanCandidate(url: folder, bytes: 1, detail: "")] },
            FixedScanner(kind: .duplicates) { _ in [CleanCandidate(url: inner, bytes: 1, detail: "")] },
        ])
        await model.lookAgain()
        #expect(model.tickedBytes == 1)   // the inner item is already inside the folder

        await model.clean()

        #expect(!exists("DerivedData"))
        #expect(model.alertMessage == nil)
    }

    @Test("A duplicate set never loses every copy: the kept copy ticked elsewhere stays")
    func keptCopyTickedElsewhere() async throws {
        let kept = try dir.file("Downloads/App.dmg", bytes: 4)
        let copy = try dir.file("Desktop/App.dmg", bytes: 4)
        let model = model([
            FixedScanner(kind: .duplicates) { _ in [CleanCandidate(url: copy, bytes: 4, detail: "", keptCopy: kept)] },
            FixedScanner(kind: .installers) { _ in [CleanCandidate(url: kept, bytes: 4, detail: "")] },
        ])
        await model.lookAgain()
        #expect(model.ticked == [kept.canonical, copy.canonical])
        #expect(model.itemsToClean.map(\.url) == [copy.canonical])
        #expect(model.tickedBytes == 4)

        await model.clean()

        #expect(exists("Downloads/App.dmg") && !exists("Desktop/App.dmg"))
    }

    @Test("A kept copy inside a ticked folder: one other copy of the set stays")
    func keptCopyInsideTickedFolder() async throws {
        let folder = try dir.folder("Downloads/Old")
        let kept = try dir.file("Downloads/Old/movie.mov", bytes: 4)
        let first = try dir.file("Desktop/movie.mov", bytes: 4)
        let second = try dir.file("Documents/movie.mov", bytes: 4)
        let model = model([
            FixedScanner(kind: .duplicates) { _ in [
                CleanCandidate(url: first, bytes: 4, detail: "", keptCopy: kept),
                CleanCandidate(url: second, bytes: 4, detail: "", keptCopy: kept),
            ] },
            FixedScanner(kind: .developerCaches) { _ in [CleanCandidate(url: folder, bytes: 4, detail: "")] },
        ])
        await model.lookAgain()

        await model.clean()

        #expect(!exists("Downloads/Old"))
        #expect(exists("Desktop/movie.mov") != exists("Documents/movie.mov"))   // exactly one copy left
    }

    @Test("Duplicates alone still trash every copy but the kept one")
    func duplicatesAlone() async throws {
        let kept = try dir.file("Documents/a.bin", bytes: 4)
        let copy = try dir.file("Desktop/a.bin", bytes: 4)
        let model = model([
            FixedScanner(kind: .duplicates) { _ in [CleanCandidate(url: copy, bytes: 4, detail: "", keptCopy: kept)] },
        ])
        await model.lookAgain()

        await model.clean()

        #expect(exists("Documents/a.bin") && !exists("Desktop/a.bin"))
    }

    @Test("Nothing ticked: Clean does nothing")
    func cleanNothing() async throws {
        let model = model([])
        await model.lookAgain()
        await model.clean()
        #expect(!undoManager.canUndo)
    }

    // MARK: - Empty Trash

    @Test("Empty Trash always asks, and deletes the Trash's contents only once confirmed")
    func emptyTrash() async throws {
        try dir.file(".Trash/old.txt", bytes: 3)
        try dir.file(".Trash/folder/inner.txt", bytes: 3)
        let model = model([])

        model.requestEmptyTrash()
        #expect(model.isConfirmingEmptyTrash)
        model.cancelEmptyTrash()
        #expect(!model.isConfirmingEmptyTrash)
        await model.confirmEmptyTrash()   // not asked anymore: nothing happens
        #expect(exists(".Trash/old.txt"))

        model.requestEmptyTrash()
        await model.confirmEmptyTrash()

        #expect(!model.isConfirmingEmptyTrash)
        #expect(exists(".Trash"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.appending(path: ".Trash").path).isEmpty)
    }

    @Test("A Trash that is a link to another folder is never emptied")
    func symlinkedTrash() async throws {
        try FileManager.default.removeItem(at: dir.url.appending(path: ".Trash"))
        try dir.file("Documents/precious.txt", bytes: 5)
        try FileManager.default.createSymbolicLink(
            at: dir.url.appending(path: ".Trash"), withDestinationURL: dir.url.appending(path: "Documents"))
        let model = model([])
        try await registerTrashUndoStep()

        model.requestEmptyTrash()
        await model.confirmEmptyTrash()

        #expect(exists("Documents/precious.txt"))
        #expect(model.alertMessage == TrashActionError.notTheTrash.localizedDescription)
        #expect(undoManager.canUndo)   // nothing was deleted
        await #expect(throws: TrashActionError.notTheTrash) { try await actions.emptyTrash(dir.url.appending(path: ".Trash")) }
    }

    @Test("The dialog closing before its button runs still empties the Trash")
    func dialogDismissedFirst() async throws {
        try dir.file(".Trash/old.txt")
        let model = model([])

        model.requestEmptyTrash()
        model.isConfirmingEmptyTrash = false   // SwiftUI resets the binding before the action
        await model.confirmEmptyTrash()

        #expect(!exists(".Trash/old.txt"))
    }

    @Test("Emptying the Trash drops the undo steps that pointed into it")
    func emptyDropsUndo() async throws {
        let file = try dir.file("cache.bin", bytes: 1)
        try dir.file(".Trash/old.txt")
        let model = model([FixedScanner(kind: .developerCaches) { _ in [CleanCandidate(url: file, bytes: 1, detail: "")] }])
        await model.lookAgain()
        await model.clean()
        #expect(undoManager.canUndo)

        model.requestEmptyTrash()
        await model.confirmEmptyTrash()

        #expect(!undoManager.canUndo)
    }

    /// A real "Move to Trash" undo step (into the test Trash); returns the trashed file.
    @discardableResult
    private func registerTrashUndoStep() async throws -> URL {
        let name = "step-\(UUID()).bin"
        try await actions.trash([try dir.file(name, bytes: 1)])
        #expect(undoManager.canUndo)
        return dir.url.appending(path: ".Trash/\(name)")
    }

    @Test("A Trash move undone then redone is still dropped by emptying; an undone one keeps its Redo")
    func emptyAfterUndoRedo() async throws {
        let first = try dir.file("first.bin", bytes: 1)
        let second = try dir.file("second.bin", bytes: 1)
        try await actions.trash([first])
        undoManager.undo()
        await actions.waitForPendingWork()
        undoManager.redo()                      // first.bin is in the Trash again
        await actions.waitForPendingWork()
        try await actions.trash([second])
        undoManager.undo()                      // second.bin is back, its Redo waits
        await actions.waitForPendingWork()
        try dir.file(".Trash/old.txt")
        let model = model([])

        model.requestEmptyTrash()
        await model.confirmEmptyTrash()

        #expect(!undoManager.canUndo)
        #expect(undoManager.canRedo && exists("second.bin"))
    }

    @Test("Emptying the Trash drops only the undo steps into the Trash; another undo step keeps its Undo")
    func emptyKeepsUnrelatedUndo() async throws {
        let file = try dir.file("cache.bin", bytes: 1)
        let draft = try dir.file("draft.txt")
        try dir.file(".Trash/old.txt")
        let model = model([FixedScanner(kind: .developerCaches) { _ in [CleanCandidate(url: file, bytes: 1, detail: "")] }])
        await model.lookAgain()
        await model.clean()
        // An undo step that has nothing to do with the Trash, such as a rename elsewhere in the app.
        let final = dir.url.appending(path: "final.txt")
        try FileManager.default.moveItem(at: draft, to: final)
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: undoManager) { _ in try? FileManager.default.moveItem(at: final, to: draft) }
        undoManager.setActionName("Rename")
        undoManager.endUndoGrouping()

        model.requestEmptyTrash()
        await model.confirmEmptyTrash()

        #expect(undoManager.undoActionName == "Rename")
        undoManager.undo()
        #expect(exists("draft.txt") && !exists("final.txt"))
        #expect(!undoManager.canUndo)   // the Smart Clean step is gone
    }

    /// A file in the test Trash that can't be deleted until `unlock` runs.
    private func lockedTrashFile(_ name: String) throws -> URL {
        let url = try dir.file(".Trash/\(name)", bytes: 1)
        #expect(chflags(url.path, UInt32(UF_IMMUTABLE)) == 0)
        return url
    }

    private func unlock(_ url: URL) { chflags(url.path, 0) }

    @Test("A partly failed Empty Trash still drops the undo steps, since some items are gone for good")
    func partlyFailedEmptyDropsUndo() async throws {
        let locked = try lockedTrashFile("locked.txt")
        defer { unlock(locked) }
        try dir.file(".Trash/gone.txt", bytes: 1)
        try await registerTrashUndoStep()
        let model = model([])

        model.requestEmptyTrash()
        await model.confirmEmptyTrash()

        #expect(!exists(".Trash/gone.txt") && exists(".Trash/locked.txt"))
        #expect(model.alertMessage != nil)
        #expect(!undoManager.canUndo)
    }

    @Test("A partly emptied folder in the Trash counts as deleted: the undo steps are dropped")
    func partlyEmptiedFolderDropsUndo() async throws {
        // Emptying goes on past an item it can't delete, so everything else in the folder goes.
        let locked = try lockedTrashFile("Box/m.txt")
        defer { unlock(locked) }
        try ["a", "b", "y", "z"].forEach { try dir.file(".Trash/Box/\($0).txt", bytes: 1) }
        let step = try await registerTrashUndoStep()
        #expect(chflags(step.path, UInt32(UF_IMMUTABLE)) == 0)   // only the folder's files can go
        defer { unlock(step) }
        let model = model([])

        model.requestEmptyTrash()
        await model.confirmEmptyTrash()

        #expect(exists(".Trash/Box/m.txt"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.appending(path: ".Trash/Box").path) == ["m.txt"])
        #expect(model.alertMessage != nil)
        #expect(!undoManager.canUndo)
    }

    @Test("Folders without search permission: an empty one is deleted, a full one is kept with a permission error")
    func unsearchableFolders() async throws {
        let empty = try dir.folder(".Trash/EmptyRO")
        try dir.file(".Trash/FullRO/inner.txt", bytes: 1)
        let full = dir.url.appending(path: ".Trash/FullRO")
        #expect(chmod(empty.path, 0o644) == 0 && chmod(full.path, 0o644) == 0)
        defer { chmod(full.path, 0o755) }
        let model = model([])

        model.requestEmptyTrash()
        await model.confirmEmptyTrash()

        #expect(!exists(".Trash/EmptyRO"))
        chmod(full.path, 0o755)
        #expect(exists(".Trash/FullRO/inner.txt"))
        #expect(model.alertMessage?.contains("“inner.txt” couldn’t be removed") == true)
    }

    @Test("A folder in the Trash that loses nothing keeps the undo steps")
    func untouchedFolderKeepsUndo() async throws {
        let locked = try lockedTrashFile("Box/m.txt")
        defer { unlock(locked) }
        let step = try await registerTrashUndoStep()
        #expect(chflags(step.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { unlock(step) }
        let model = model([])

        model.requestEmptyTrash()
        await model.confirmEmptyTrash()

        #expect(exists(".Trash/Box/m.txt"))
        #expect(model.alertMessage != nil)
        #expect(undoManager.canUndo)
    }

    @Test("Emptying a Trash already emptied elsewhere (Finder) drops the undo steps that pointed into it")
    func alreadyEmptyTrashDropsUndo() async throws {
        let step = try await registerTrashUndoStep()
        try FileManager.default.removeItem(at: step)   // emptied in Finder
        let model = model([])

        model.requestEmptyTrash()
        await model.confirmEmptyTrash()

        #expect(model.alertMessage == nil)
        #expect(!undoManager.canUndo)
    }

    @Test("An Empty Trash that deleted nothing keeps the undo steps")
    func failedEmptyKeepsUndo() async throws {
        let locked = try lockedTrashFile("locked.txt")
        defer { unlock(locked) }
        let step = try await registerTrashUndoStep()
        #expect(chflags(step.path, UInt32(UF_IMMUTABLE)) == 0)   // nothing in the Trash can go
        defer { unlock(step) }
        let model = model([])

        model.requestEmptyTrash()
        await model.confirmEmptyTrash()

        #expect(exists(".Trash/locked.txt"))
        #expect(model.alertMessage != nil)
        #expect(undoManager.canUndo)
    }

    @Test("An item the user unticked stays unticked when a slower suggestion lists it too")
    func untickSticks() async throws {
        let dmg = try dir.file("Downloads/App.dmg", bytes: 4)
        let gate = Gate()
        let model = model([
            FixedScanner(kind: .installers) { _ in [CleanCandidate(url: dmg, bytes: 4, detail: "")] },
            SlowScanner(kind: .duplicates, gate: gate) { [CleanCandidate(url: dmg, bytes: 4, detail: "")] },
        ])
        let scan = Task { await model.lookAgain() }
        while !model.isTicked(dmg) { await Task.yield() }

        model.toggle(dmg)
        await gate.open()
        await scan.value

        #expect(!model.isTicked(dmg))
    }

    @Test("Clean does nothing while a scan is still running: nothing goes until every suggestion is in")
    func noCleanDuringScan() async throws {
        let cache = try dir.file("cache.bin", bytes: 4)
        let gate = Gate()
        let model = model([
            FixedScanner(kind: .developerCaches) { _ in [CleanCandidate(url: cache, bytes: 4, detail: "")] },
            SlowScanner(kind: .duplicates, gate: gate) { [] },
        ])
        let scan = Task { await model.lookAgain() }
        while !model.isTicked(cache) { await Task.yield() }
        #expect(model.isScanning)

        // Cleaning starts while Duplicates is still looking; the scan is let finish afterwards.
        let cleaning = Task { await model.clean() }
        await gate.open()
        await cleaning.value
        await scan.value

        #expect(exists("cache.bin") && !exists(".Trash/cache.bin"))
        #expect(!undoManager.canUndo)
    }

    @Test("An item listed by Safe to clear starts ticked even when a Your call suggestion lists it first")
    func safeTickWinsWhicheverFinishesFirst() async throws {
        let dmg = try dir.file("Downloads/App.dmg", bytes: 4)
        let gate = Gate()
        let model = model([
            SlowScanner(kind: .installers, gate: gate) { [CleanCandidate(url: dmg, bytes: 4, detail: "")] },
            FixedScanner(kind: .oldDownloads) { _ in [CleanCandidate(url: dmg, bytes: 4, detail: "")] },
        ])
        let scan = Task { await model.lookAgain() }
        while model.suggestion(.oldDownloads)?.candidates.isEmpty != false { await Task.yield() }
        #expect(!model.isTicked(dmg))

        await gate.open()
        await scan.value

        #expect(model.isTicked(dmg))
    }

    @Test("Ticking a whole suggestion counts as the user's choice: a slower one doesn't change it")
    func setAllSticks() async throws {
        let dmg = try dir.file("Downloads/App.dmg", bytes: 4)
        let gate = Gate()
        let model = model([
            FixedScanner(kind: .oldDownloads) { _ in [CleanCandidate(url: dmg, bytes: 4, detail: "")] },
            SlowScanner(kind: .installers, gate: gate) { [CleanCandidate(url: dmg, bytes: 4, detail: "")] },
        ])
        let scan = Task { await model.lookAgain() }
        while model.suggestion(.oldDownloads)?.candidates.isEmpty != false { await Task.yield() }
        model.setAll(.oldDownloads, ticked: true)
        model.setAll(.oldDownloads, ticked: false)

        await gate.open()
        await scan.value

        #expect(!model.isTicked(dmg))
    }

    @Test("Looking again cancels the older scan, so it stops working in the background")
    func lookAgainCancelsOlderScan() async throws {
        let probe = ScanProbe()
        let model = model([UntilCancelledScanner(kind: .duplicates, probe: probe)])
        let first = Task { await model.lookAgain() }
        while await probe.started < 1 { await Task.yield() }

        let second = Task { await model.lookAgain() }
        #expect(await probe.waitForCancellation())
        await first.value
        await probe.release()
        await second.value
        #expect(!model.isScanning)
    }

    @Test("Closing the window (cancelling Look Again) cancels its scan")
    func cancellingLookAgainCancelsScan() async throws {
        let probe = ScanProbe()
        let model = model([UntilCancelledScanner(kind: .duplicates, probe: probe)])
        let scan = Task { await model.lookAgain() }
        while await probe.started < 1 { await Task.yield() }

        scan.cancel()

        #expect(await probe.waitForCancellation())
        await scan.value
    }

    @Test("Closing the window cancels a scan started by the Look Again button")
    func closingCancelsButtonScan() async throws {
        let probe = ScanProbe()
        let model = model([UntilCancelledScanner(kind: .duplicates, probe: probe)])
        let button = Task { await model.lookAgain() }   // the button's own, never-cancelled task
        while await probe.started < 1 { await Task.yield() }

        model.stopScanning()

        #expect(await probe.waitForCancellation())
        await button.value
        #expect(!model.isScanning)
    }

    @Test("An item gone since the scan doesn't stop the others from being cleaned")
    func vanishedItem() async throws {
        let a = try dir.file("a.bin", bytes: 1)
        let b = try dir.file("b.bin", bytes: 1)
        let c = try dir.file("c.bin", bytes: 1)
        let model = model([FixedScanner(kind: .developerCaches) { _ in
            [a, b, c].map { CleanCandidate(url: $0, bytes: 1, detail: "") }
        }])
        await model.lookAgain()
        try FileManager.default.removeItem(at: b)

        await model.clean()

        #expect(!exists("a.bin") && !exists("c.bin"))
        #expect(model.alertMessage == nil)
    }

    @Test("An older scan that measures late never resets the newer scan's storage overview")
    func olderScanKeepsNewerStorage() async throws {
        let calls = CallCounter(), gate = Gate()
        let home = dir.url
        let model = SmartCleanModel(
            actions: actions, scanners: [], environment: { CleanEnvironment.testing(home: home) },
            capacity: { _ in
                if await calls.next() == 1 {
                    await gate.wait()
                    return (total: 999, available: 1)   // the older scan's, arriving last
                }
                return (total: 1_000, available: 500)
            })
        let older = Task { await model.lookAgain() }
        while await calls.count < 1 { await Task.yield() }

        await model.lookAgain()
        #expect(model.storage?.total == 1_000 && model.storage?.trash != nil)
        await gate.open()
        await older.value

        #expect(model.storage?.total == 1_000 && model.storage?.trash != nil)
    }

    @Test("Your files leave out ~/Applications, which Apps already counts")
    func noDoubleCountedApps() async throws {
        try dir.file("Applications/Big.app/Contents/bin", bytes: 1000)
        try dir.file("Documents/doc", bytes: 10)
        let env = environment()
        #expect(await StorageOverview.measureApps(env) == 1000)
        #expect(await StorageOverview.measureYourFiles(env) == 10)
    }

    // MARK: - Storage

    @Test("Storage: used, System as the rest, and the volume's real capacity")
    func storage() throws {
        var overview = StorageOverview(total: 1_000, available: 200)
        #expect(overview.used == 800)
        #expect(overview.system == nil)   // not everything measured yet
        overview.apps = 100
        overview.yourFiles = 300
        overview.other = 150
        overview.trash = 50
        #expect(overview.system == 200)

        let real = try #require(StorageOverview.capacity(of: dir.url))
        #expect(real.total > 0 && real.available > 0 && real.available <= real.total)
    }

    @Test("Your files skip ~/Library and the Trash, which count as Other and In the Trash")
    func storageCategories() async throws {
        try dir.file("Documents/a.bin", bytes: 100)
        try dir.file(".npm/x", bytes: 10)
        try dir.file("Library/Caches/c.bin", bytes: 40)
        try dir.file(".Trash/t.bin", bytes: 5)
        let env = environment()

        #expect(await StorageOverview.measureYourFiles(env) == 110)
        #expect(await StorageOverview.measureOther(env) == 40)
        #expect(await StorageOverview.measureTrash(env) == 5)
    }

}

/// Counts the scans of an `UntilCancelledScanner` and whether one was cancelled.
actor ScanProbe {
    private(set) var started = 0
    private(set) var cancelled = 0
    private(set) var isReleased = false

    func start() -> Int { started += 1; return started }
    func markCancelled() { cancelled += 1 }
    func release() { isReleased = true }

    /// Whether a scan was cancelled within 5 s.
    func waitForCancellation() async -> Bool {
        let deadline = Date.now.addingTimeInterval(5)
        while cancelled == 0, Date.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        return cancelled > 0
    }
}

/// Its first scan works until it is cancelled (or released after 5 s at most); later scans
/// finish once released.
struct UntilCancelledScanner: SuggestionScanner {
    let kind: SuggestionKind
    let probe: ScanProbe

    func scan(_ environment: CleanEnvironment) async throws -> [CleanCandidate] {
        let run = await probe.start()
        let deadline = Date.now.addingTimeInterval(5)
        while Date.now < deadline {
            if Task.isCancelled {
                await probe.markCancelled()
                throw CancellationError()
            }
            if run > 1, await probe.isReleased { return [] }
            await Task.yield()
        }
        return []
    }
}

/// Counts calls across tasks.
actor CallCounter {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}

/// Lets a test decide when a slow scanner finishes.
actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

struct SlowScanner: SuggestionScanner {
    let kind: SuggestionKind
    let gate: Gate
    let candidates: @Sendable () -> [CleanCandidate]

    func scan(_ environment: CleanEnvironment) async throws -> [CleanCandidate] {
        await gate.wait()
        return candidates()
    }
}
