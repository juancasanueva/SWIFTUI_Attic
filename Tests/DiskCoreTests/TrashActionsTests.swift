import Foundation
import Testing
@testable import DiskCore

@MainActor
@Suite("Trash actions: Move to Trash with Undo, Empty Trash")
struct TrashActionsTests {
    let dir: TemporaryDirectory
    let undoManager: UndoManager
    let actions: TrashActions

    init() throws {
        dir = try TemporaryDirectory()
        try dir.folder(".Trash")
        undoManager = UndoManager()
        undoManager.groupsByEvent = false
        actions = TrashActions.withTestTrash(dir.url.appending(path: ".Trash"))
        actions.undoManager = undoManager
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.url.appending(path: path).path)
    }

    @Test("The Trash is checked when it's emptied: one swapped for a link while queued is never emptied")
    func trashSwappedWhileQueued() async throws {
        try dir.file("Documents/precious.txt", bytes: 5)
        try dir.file(".Trash/old.txt")
        let source = try dir.file("a.txt")
        let trash = dir.url.appending(path: ".Trash")
        let reached = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        // A Move to Trash that waits inside the trasher holds the queue.
        let actions = TrashActions(trashFolder: trash, trasher: { url in
            reached.signal()
            release.wait()
            return nil
        })
        let trashing = Task { try await actions.trash([source]) }
        await withCheckedContinuation { done in DispatchQueue.global().async { reached.wait(); done.resume() } }
        let empty = Task { try await actions.emptyTrash(trash) }
        while actions.queuedOperations == 0 { await Task.yield() }

        try FileManager.default.removeItem(at: trash)
        try FileManager.default.createSymbolicLink(at: trash, withDestinationURL: dir.url.appending(path: "Documents"))
        release.signal()
        _ = try? await trashing.value

        await #expect(throws: TrashActionError.notTheTrash) { try await empty.value }
        #expect(exists("Documents/precious.txt"))
    }

    @Test("A Trash swapped for a link halfway through emptying stops before touching the link's folder")
    func trashSwappedDuringDeletion() async throws {
        let count = 3000
        for index in 0..<count {
            try dir.file(".Trash/n\(index)", bytes: 1)
            try dir.file("Documents/n\(index)", bytes: 1)
        }
        let root = dir.url
        let trash = root.appending(path: ".Trash")
        let swapper = Thread {
            // Gives up after 10 s or when the listing fails, so the test never hangs.
            let deadline = Date.now.addingTimeInterval(10)
            while ((try? FileManager.default.contentsOfDirectory(atPath: trash.path).count) ?? 0) > count - 50,
                  Date.now < deadline {}
            try? FileManager.default.moveItem(at: trash, to: root.appending(path: ".Trash-real"))
            try? FileManager.default.createSymbolicLink(at: trash, withDestinationURL: root.appending(path: "Documents"))
        }
        try await registerTrashUndoStep()
        swapper.start()

        await #expect(throws: TrashActionError.notTheTrash) { try await actions.emptyTrash(trash) }
        while swapper.isExecuting { try await Task.sleep(for: .milliseconds(5)) }

        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Documents").path).count == count)
        #expect(!undoManager.canUndo)   // stopped after deleting some: they are gone for good
    }

    @Test("A link inside the Trash is deleted, never followed: the folder it points to stays")
    func linkInsideTrashNotFollowed() async throws {
        try dir.file("Documents/precious.txt", bytes: 5)
        try dir.folder(".Trash/Box")
        try FileManager.default.createSymbolicLink(
            at: dir.url.appending(path: ".Trash/Box/docs"), withDestinationURL: dir.url.appending(path: "Documents"))
        try FileManager.default.createSymbolicLink(
            at: dir.url.appending(path: ".Trash/docs"), withDestinationURL: dir.url.appending(path: "Documents"))

        try await actions.emptyTrash(dir.url.appending(path: ".Trash"))

        #expect(exists("Documents/precious.txt"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.appending(path: ".Trash").path).isEmpty)
    }

    /// A real "Move to Trash" undo step (into the test Trash); returns the trashed file.
    @discardableResult
    private func registerTrashUndoStep() async throws -> URL {
        let name = "step-\(UUID()).bin"
        try await actions.trash([try dir.file(name, bytes: 1)])
        #expect(undoManager.canUndo)
        return dir.url.appending(path: ".Trash/\(name)")
    }

    @Test("Moves into another volume's Trash (.Trashes) keep their Undo: Empty Trash doesn't empty it")
    func otherVolumeTrashKeepsUndo() async throws {
        let file = try dir.file("a.txt", bytes: 1)
        let otherTrash = try dir.folder(".Trashes/501")
        let actions = TrashActions.trashing(into: otherTrash, trashFolder: dir.url.appending(path: ".Trash"))
        actions.undoManager = undoManager
        try await actions.trash([file])

        actions.dropTrashUndo()

        #expect(undoManager.undoActionName == "Move to Trash")
    }

    @Test("Move to Trash fills the TrashActions' own Trash: tests never touch the real one")
    func trashesIntoOwnTrash() async throws {
        let file = try dir.file("cache.bin", bytes: 1)
        try await actions.trash([file])
        #expect(exists(".Trash/cache.bin") && !exists("cache.bin"))
        undoManager.undo()
        await actions.waitForPendingWork()
        #expect(exists("cache.bin") && !exists(".Trash/cache.bin"))
    }

    @Test("Another folder named .Trash isn't the Trash: moves into it keep their Undo, and it is never emptied")
    func otherTrashNamedFolder() async throws {
        let file = try dir.file("a.txt", bytes: 1)
        let lookalike = try dir.folder("Documents/.Trash")
        let actions = TrashActions.trashing(into: lookalike, trashFolder: dir.url.appending(path: ".Trash"))
        actions.undoManager = undoManager
        try await actions.trash([file])

        actions.dropTrashUndo()

        #expect(undoManager.undoActionName == "Move to Trash")
        await #expect(throws: TrashActionError.notTheTrash) { try await actions.emptyTrash(lookalike) }
        #expect(exists("Documents/.Trash/a.txt"))
    }

    @Test("A very deep folder in the Trash is emptied without running out of stack")
    func deepFolderEmptied() async throws {
        // Built with descriptors: the path would be too long for path-based calls.
        var folder = open(dir.url.appending(path: ".Trash").path, O_RDONLY | O_DIRECTORY)
        for _ in 0..<600 {
            #expect(mkdirat(folder, "d", 0o755) == 0)
            let child = openat(folder, "d", O_RDONLY | O_DIRECTORY)
            close(folder)
            folder = child
        }
        let leaf = openat(folder, "leaf.txt", O_WRONLY | O_CREAT, 0o644)
        #expect(leaf >= 0)
        close(leaf)
        close(folder)

        try await actions.emptyTrash(dir.url.appending(path: ".Trash"))

        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.appending(path: ".Trash").path).isEmpty)
    }

    @Test("A folder deeper than the open-file limit is emptied: descriptors don't pile up per level")
    func deeperThanDescriptorLimit() async {
        // In a child process whose open-file limit is lowered to 64, below the folder's depth.
        await #expect(processExitsWith: .success) {
            guard try await TrashActionsTests.emptyDeepTrash(depth: 200, descriptorLimit: 64) else { exit(1) }
        }
    }

    /// Empties a Trash holding one folder `depth` levels deep, with at most `descriptorLimit`
    /// open files; whether it ended empty.
    static func emptyDeepTrash(depth: Int, descriptorLimit: rlim_t) async throws -> Bool {
        let root = FileManager.default.temporaryDirectory.appending(path: "DiskCoreTests-\(UUID())")
        let trash = root.appending(path: ".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        var folder = open(trash.path, O_RDONLY | O_DIRECTORY)
        for _ in 0..<depth {
            guard mkdirat(folder, "d", 0o755) == 0 else { return false }
            let child = openat(folder, "d", O_RDONLY | O_DIRECTORY)
            close(folder)
            folder = child
        }
        close(folder)
        var limit = rlimit()
        getrlimit(RLIMIT_NOFILE, &limit)
        limit.rlim_cur = descriptorLimit
        guard setrlimit(RLIMIT_NOFILE, &limit) == 0 else { return false }

        let actions = TrashActions.withTestTrash(
            trash)
        try await actions.emptyTrash(trash)
        let isEmpty = try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty
        try? FileManager.default.removeItem(at: root)
        return isEmpty
    }

    @Test("A folder moved out of the Trash while it is being emptied stops being emptied")
    func movedOutWhileEmptying() async throws {
        let count = 200
        for index in 0..<count { try dir.file(".Trash/Box/n\(index)", bytes: 1) }
        let box = dir.url.appending(path: ".Trash/Box")
        let rescued = try dir.folder("Desktop").appending(path: "Box")
        let boxInode = inode(of: box)
        let checks = Counter()
        // Moved right before Box's 50th parent check: once on entering it, then once before
        // each entry, so after 48 of its files went.
        let actions = actions(walk: TrashActions.TrashWalk(listEntries: TrashActions.TrashWalk.system.listEntries) { folder in
            if isFolder(folder, boxInode), checks.next() == 50 { try? FileManager.default.moveItem(at: box, to: rescued) }
            return TrashActions.TrashWalk.system.parentOf(folder)
        })

        await #expect(throws: TrashActionError.movedWhileEmptying("Box")) { try await actions.emptyTrash(dir.url.appending(path: ".Trash")) }

        #expect(try FileManager.default.contentsOfDirectory(atPath: rescued.path).count == count - 48)
    }

    @Test("A folder whose parent can't be read is reported as that failure, never as moved")
    func unreadableParentNotMoved() async throws {
        try dir.file(".Trash/Box/a.txt", bytes: 1)
        try dir.folder(".Trash/Empty")
        let failing = [inode(of: dir.url.appending(path: ".Trash/Box")), inode(of: dir.url.appending(path: ".Trash/Empty"))]
        let actions = actions(walk: TrashActions.TrashWalk(listEntries: TrashActions.TrashWalk.system.listEntries) { folder in
            failing.contains { isFolder(folder, $0) } ? .failure(TrashActions.SystemCallError(code: EIO)) : TrashActions.TrashWalk.system.parentOf(folder)
        })

        await #expect { try await actions.emptyTrash(dir.url.appending(path: ".Trash")) } throws: { error in
            error.localizedDescription == "“Box” couldn’t be removed."
        }

        #expect(exists(".Trash/Box/a.txt"))
        #expect(!exists(".Trash/Empty"))   // nothing in it to reach: it still goes
    }

    @Test("A parent check failing midway is reported as that failure, never taken as a move")
    func parentFailureMidway() async throws {
        for index in 0..<10 { try dir.file(".Trash/Box/f\(index)", bytes: 1) }
        try dir.file(".Trash/other.txt", bytes: 1)
        let boxInode = inode(of: dir.url.appending(path: ".Trash/Box"))
        let checks = Counter()
        let actions = actions(walk: TrashActions.TrashWalk(listEntries: TrashActions.TrashWalk.system.listEntries) { folder in
            if isFolder(folder, boxInode), checks.next() >= 5 { return .failure(TrashActions.SystemCallError(code: EIO)) }
            return TrashActions.TrashWalk.system.parentOf(folder)
        })

        await #expect { try await actions.emptyTrash(dir.url.appending(path: ".Trash")) } throws: { error in
            error.localizedDescription == "“Box” couldn’t be removed."
        }

        // Box's first 3 files went before its 5th check failed; the rest of the Trash still went.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.appending(path: ".Trash/Box").path).count == 7)
        #expect(!exists(".Trash/other.txt"))
    }

    @Test("A parent check saying a full folder is gone is reported, never ignored")
    func parentGoneReported() async throws {
        try dir.file(".Trash/Full/a.txt", bytes: 1)
        let fullInode = inode(of: dir.url.appending(path: ".Trash/Full"))
        let actions = actions(walk: TrashActions.TrashWalk(listEntries: TrashActions.TrashWalk.system.listEntries) { folder in
            isFolder(folder, fullInode) ? .failure(TrashActions.SystemCallError(code: ENOENT)) : TrashActions.TrashWalk.system.parentOf(folder)
        })

        await #expect { try await actions.emptyTrash(dir.url.appending(path: ".Trash")) } throws: { error in
            error.localizedDescription == "“Full” couldn’t be removed."
        }
        #expect(exists(".Trash/Full/a.txt"))
    }

    @Test("A parent check midway saying the folder is gone is reported, never ignored")
    func parentGoneMidway() async throws {
        for index in 0..<10 { try dir.file(".Trash/Box/f\(index)", bytes: 1) }
        let boxInode = inode(of: dir.url.appending(path: ".Trash/Box"))
        let checks = Counter()
        let actions = actions(walk: TrashActions.TrashWalk(listEntries: TrashActions.TrashWalk.system.listEntries) { folder in
            if isFolder(folder, boxInode), checks.next() >= 5 { return .failure(TrashActions.SystemCallError(code: ENOENT)) }
            return TrashActions.TrashWalk.system.parentOf(folder)
        })

        await #expect { try await actions.emptyTrash(dir.url.appending(path: ".Trash")) } throws: { error in
            error.localizedDescription == "“Box” couldn’t be removed."
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.appending(path: ".Trash/Box").path).count == 7)
    }

    @Test("A path into the Trash spelled through a link or in other letter case still counts as the Trash")
    func trashSpelledDifferently() async throws {
        let first = try dir.file("a.txt", bytes: 1)
        let second = try dir.file("b.txt", bytes: 1)
        let alias = dir.url.appending(path: "TrashAlias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: dir.url.appending(path: ".Trash"))
        let trash = dir.url.appending(path: ".Trash")
        let otherCase = dir.url.appending(path: ".TRASH")
        // One TrashActions: a.txt goes in through the link, b.txt through the other letter case.
        let actions = TrashActions(trashFolder: trash, trasher: { url in
            let destination = (url.lastPathComponent == "a.txt" ? alias : otherCase).appending(path: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        })
        actions.undoManager = undoManager
        try await actions.trash([first])
        #expect(exists(".Trash/a.txt"))
        // Other letter case names the same folder only on a case-insensitive volume.
        let caseSensitive = try dir.url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames ?? false
        if !caseSensitive {
            try await actions.trash([second])
            #expect(exists(".Trash/b.txt"))
        }

        actions.dropTrashUndo()

        #expect(!undoManager.canUndo)
    }

    @Test("A folder whose ancestor is moved out of the Trash mid-empty stops being emptied at the next ancestor check")
    func ancestorMovedOut() async throws {
        for index in 0..<200 { try dir.file(".Trash/Top/Mid/Deep/f\(index)", bytes: 1) }
        let mid = dir.url.appending(path: ".Trash/Top/Mid")
        let rescued = try dir.folder("Desktop").appending(path: "Mid")
        let deepInode = inode(of: mid.appending(path: "Deep"))
        let checks = Counter()
        // Mid (neither the top-level folder nor Deep's parent check would notice) goes after 3 of Deep's files; the ancestor check at step 64 stops it 59 files later.
        let actions = actions(walk: TrashActions.TrashWalk(listEntries: TrashActions.TrashWalk.system.listEntries) { folder in
            if isFolder(folder, deepInode), checks.next() == 5 { try? FileManager.default.moveItem(at: mid, to: rescued) }
            return TrashActions.TrashWalk.system.parentOf(folder)
        })

        await #expect(throws: TrashActionError.movedWhileEmptying("Mid")) { try await actions.emptyTrash(dir.url.appending(path: ".Trash")) }

        #expect(try FileManager.default.contentsOfDirectory(atPath: rescued.appending(path: "Deep").path).count == 138)
    }

    @Test("A top-level folder moved out of the Trash while a folder deep inside it is emptied stops at the next item, naming it")
    func topMovedWhileDeep() async throws {
        for index in 0..<200 { try dir.file(".Trash/Top/A/Deep/f\(index)", bytes: 1) }
        let top = dir.url.appending(path: ".Trash/Top")
        let rescued = try dir.folder("Desktop").appending(path: "Top")
        let deepInode = inode(of: top.appending(path: "A/Deep"))
        let checks = Counter()
        let actions = actions(walk: TrashActions.TrashWalk(listEntries: TrashActions.TrashWalk.system.listEntries) { folder in
            if isFolder(folder, deepInode), checks.next() == 5 { try? FileManager.default.moveItem(at: top, to: rescued) }
            return TrashActions.TrashWalk.system.parentOf(folder)
        })

        await #expect(throws: TrashActionError.movedWhileEmptying("Top")) { try await actions.emptyTrash(dir.url.appending(path: ".Trash")) }

        #expect(try FileManager.default.contentsOfDirectory(atPath: rescued.appending(path: "A/Deep").path).count == 197)
    }

    @Test("An ancestor that can't be read while checking for moves is reported as that failure")
    func ancestorUnreadableReported() async throws {
        for index in 0..<100 { try dir.file(".Trash/Top/Mid/Deep/f\(index)", bytes: 1) }
        try dir.file(".Trash/other.txt", bytes: 1)
        let midInode = inode(of: dir.url.appending(path: ".Trash/Top/Mid"))
        let checks = Counter()
        // Mid's own checks pass (entering it, then before entering Deep); the ancestor check from Deep (at step 64) fails.
        let actions = actions(walk: TrashActions.TrashWalk(listEntries: TrashActions.TrashWalk.system.listEntries) { folder in
            if isFolder(folder, midInode), checks.next() >= 3 { return .failure(TrashActions.SystemCallError(code: EIO)) }
            return TrashActions.TrashWalk.system.parentOf(folder)
        })

        await #expect { try await actions.emptyTrash(dir.url.appending(path: ".Trash")) } throws: { error in
            error.localizedDescription == "“Mid” couldn’t be removed."
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.appending(path: ".Trash/Top/Mid/Deep").path).count == 38)
        #expect(!exists(".Trash/other.txt"))
    }

    @Test("An ancestor moved out of the Trash is noticed however deep the folder being emptied is")
    func deepAncestorMovedOut() async throws {
        // 400 levels below Top/d: "../" that many times is longer than a path may be.
        let top = try dir.folder(".Trash/Top")
        var folder = open(top.path, O_RDONLY | O_DIRECTORY)
        for _ in 0..<400 {
            #expect(mkdirat(folder, "d", 0o755) == 0)
            let child = openat(folder, "d", O_RDONLY | O_DIRECTORY)
            close(folder)
            folder = child
        }
        for index in 0..<200 {
            let file = openat(folder, "f\(index)", O_WRONLY | O_CREAT, 0o644)
            close(file)
        }
        var info = stat()
        fstat(folder, &info)
        close(folder)
        let leafInode = info.st_ino
        let rescued = try dir.folder("Desktop").appending(path: "d")
        let checks = Counter()
        let actions = actions(walk: TrashActions.TrashWalk(listEntries: TrashActions.TrashWalk.system.listEntries) { folder in
            if isFolder(folder, leafInode), checks.next() == 5 { try? FileManager.default.moveItem(at: top.appending(path: "d"), to: rescued) }
            return TrashActions.TrashWalk.system.parentOf(folder)
        })

        await #expect(throws: TrashActionError.movedWhileEmptying("d")) { try await actions.emptyTrash(dir.url.appending(path: ".Trash")) }

        // Climb to the leaf by descriptors and count what's left in it.
        folder = open(rescued.path, O_RDONLY | O_DIRECTORY)
        for _ in 0..<399 {
            let child = openat(folder, "d", O_RDONLY | O_DIRECTORY)
            close(folder)
            folder = child
        }
        #expect(folder >= 0)
        let left = (try? TrashActions.entryNames(of: folder).get().count) ?? -1
        close(folder)
        // Moved after 3 of its files; the next ancestor check (every 64 steps) comes 45 files later.
        #expect(left == 152)
    }

    @Test("A top-level folder renamed inside the Trash mid-empty is still emptied, never reported as moved")
    func topRenamedInTrash() async throws {
        for index in 0..<20 { try dir.file(".Trash/Top/A/Deep/f\(index)", bytes: 1) }
        try dir.file(".Trash/other.txt", bytes: 1)
        let top = dir.url.appending(path: ".Trash/Top")
        let deepInode = inode(of: top.appending(path: "A/Deep"))
        let checks = Counter()
        let renamed = dir.url.appending(path: ".Trash/Renamed")
        let actions = actions(walk: TrashActions.TrashWalk(listEntries: TrashActions.TrashWalk.system.listEntries) { folder in
            if isFolder(folder, deepInode), checks.next() == 5 { try? FileManager.default.moveItem(at: top, to: renamed) }
            return TrashActions.TrashWalk.system.parentOf(folder)
        })

        try await actions.emptyTrash(dir.url.appending(path: ".Trash"))

        // Its contents went; the folder itself, known only by its old name, stays (empty).
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.appending(path: ".Trash").path) == ["Renamed"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.appending(path: ".Trash/Renamed").path).isEmpty)
    }

    @Test("A top-level folder deleted elsewhere mid-empty is reported as a failure, never as moved")
    func topDeletedElsewhere() async throws {
        for index in 0..<20 { try dir.file(".Trash/Top/A/Deep/f\(index)", bytes: 1) }
        try dir.file(".Trash/other.txt", bytes: 1)
        let top = dir.url.appending(path: ".Trash/Top")
        let deepInode = inode(of: top.appending(path: "A/Deep"))
        let checks = Counter()
        let actions = actions(walk: TrashActions.TrashWalk(listEntries: TrashActions.TrashWalk.system.listEntries) { folder in
            if isFolder(folder, deepInode), checks.next() == 5 { try? FileManager.default.removeItem(at: top) }
            return TrashActions.TrashWalk.system.parentOf(folder)
        })

        // The open folder's parent can't be told apart from a failure (L42): reported, as "couldn't be removed".
        await #expect { try await actions.emptyTrash(dir.url.appending(path: ".Trash")) } throws: { error in
            error.localizedDescription == "“Deep” couldn’t be removed."
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.appending(path: ".Trash").path).isEmpty)
    }

    @Test("A folder whose listing fails is kept with that failure")
    func listingFailureReported() async throws {
        try dir.file(".Trash/Box/a.txt", bytes: 1)
        try dir.file(".Trash/other.txt", bytes: 1)
        let boxInode = inode(of: dir.url.appending(path: ".Trash/Box"))
        let actions = actions(walk: TrashActions.TrashWalk(listEntries: { folder in
            isFolder(folder, boxInode) ? .failure(TrashActions.SystemCallError(code: EIO)) : TrashActions.TrashWalk.system.listEntries(folder)
        }, parentOf: TrashActions.TrashWalk.system.parentOf))

        await #expect { try await actions.emptyTrash(dir.url.appending(path: ".Trash")) } throws: { error in
            error.localizedDescription == "“Box” couldn’t be removed."
        }

        #expect(exists(".Trash/Box/a.txt") && !exists(".Trash/other.txt"))
    }

    /// TrashActions on the test Trash whose Empty Trash makes `walk`'s calls.
    private func actions(walk: TrashActions.TrashWalk) -> TrashActions {
        TrashActions.withTestTrash(
            dir.url.appending(path: ".Trash"), walk: walk)
    }

    @Test("Emptying refuses any folder that isn't a Trash")
    func emptyOnlyTrash() async throws {
        let folder = try dir.folder("Documents")
        try dir.file("Documents/precious.txt")
        await #expect(throws: TrashActionError.notTheTrash) { try await actions.emptyTrash(folder) }
        #expect(exists("Documents/precious.txt"))
    }
}

extension TrashActions {
    /// TrashActions whose Move to Trash puts items into `folder`, while Empty Trash empties `trashFolder`.
    static func trashing(into folder: URL, trashFolder: URL) -> TrashActions {
        TrashActions(trashFolder: trashFolder, trasher: { url in
            let destination = TrashActions.uniqueDestination(for: url, in: folder, copyStyle: false)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        })
    }

    /// TrashActions whose Move to Trash fills `trash` (a test home's), never the real Trash.
    static func withTestTrash(_ trash: URL, walk: TrashWalk = .system) -> TrashActions {
        TrashActions(trashFolder: trash, trasher: { url in
            let destination = TrashActions.uniqueDestination(for: url, in: trash, copyStyle: false)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }, trashWalk: walk)
    }
}

/// A file's inode.
func inode(of url: URL) -> ino_t {
    var info = stat()
    lstat(url.path, &info)
    return info.st_ino
}

/// Whether the open descriptor is the file with `inode`.
func isFolder(_ descriptor: Int32, _ inode: ino_t) -> Bool {
    var info = stat()
    return fstat(descriptor, &info) == 0 && info.st_ino == inode
}

/// A thread-safe count, for hooks called from the walk's thread.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
