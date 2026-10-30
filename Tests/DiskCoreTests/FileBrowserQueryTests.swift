import Foundation
import Testing
@testable import DiskCore

@Suite struct FileBrowserQueryTests {
    private func names(_ query: FileBrowserQuery, _ tree: FileTree, focus: NodeID = FileTree.rootID) throws -> [String] {
        try query.results(in: tree, focus: focus).map { tree[$0].name }
    }

    @Test func noCriteriaListsTheFocusedFolderLargestFirst() throws {
        #expect(try names(FileBrowserQuery(), sampleTree()) == ["a", "b.app", "c.bin"])
    }

    @Test func textSearchesAllDescendantsOfTheFocus() throws {
        let tree = sampleTree()
        var query = FileBrowserQuery()
        query.text = "BIN"
        #expect(try names(query, tree) == ["x.bin", "c.bin"])
        #expect(try names(query, tree, focus: tree.id("a")) == ["x.bin"])
    }

    @Test func entireScanScopeIgnoresTheFocus() throws {
        let tree = sampleTree()
        var query = FileBrowserQuery()
        query.text = "c.bin"
        query.scope = .entireScan
        #expect(try names(query, tree, focus: tree.id("a")) == ["c.bin"])
    }

    @Test func kindFilterSearchesTheFocusForMatchingItems() throws {
        var query = FileBrowserQuery()
        query.kinds = [.package]
        #expect(try names(query, sampleTree()) == ["b.app"])
        query.kinds = [.folder]
        #expect(try names(query, sampleTree()) == ["a"])
        query.kinds = [.file]
        #expect(try names(query, sampleTree()) == ["x.bin", "z", "y.txt", "c.bin"])
    }

    @Test func sizeFilterUsesAllocatedSizeAcrossTheFocus() throws {
        var query = FileBrowserQuery()
        query.minimumSize = 350
        #expect(try names(query, sampleTree()) == ["a", "x.bin"])
    }

    @Test(arguments: [
        (FileBrowserQuery.SortField.name, true, ["a", "b.app", "c.bin"]),
        (.name, false, ["c.bin", "b.app", "a"]),
        (.allocatedSize, true, ["c.bin", "b.app", "a"]),
        (.fileCount, false, ["a", "b.app", "c.bin"]),
    ])
    func sortsByField(field: FileBrowserQuery.SortField, ascending: Bool, expected: [String]) throws {
        var query = FileBrowserQuery()
        query.sortField = field
        query.ascending = ascending
        #expect(try names(query, sampleTree()) == expected)
    }

    @Test func removedItemsAreNotFound() throws {
        let tree = sampleTree()
        let updated = tree.removing([tree.id("a")])
        var query = FileBrowserQuery()
        query.text = "x.bin"
        #expect(try names(query, updated).isEmpty)
    }

    @Test func cancelledSearchThrows() async {
        let tree = sampleTree()
        var query = FileBrowserQuery()
        query.text = "x"
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try query.results(in: tree, focus: FileTree.rootID)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}

@Suite struct DiscardPileTests {
    @Test func aFolderAbsorbsItemsInsideIt() {
        let tree = sampleTree()
        var pile = DiscardPile()
        pile.add(tree.id("a/x.bin"))
        pile.add(tree.id("a"))
        pile.add(tree.id("c.bin"))

        let plan = pile.plan(in: tree, policy: TrashSafetyPolicy(homePath: "/Users/me"))

        #expect(plan.moves == [tree.id("a"), tree.id("c.bin")])
        #expect(plan.bytes == 700)
        #expect(plan.refusals.isEmpty)
    }

    @Test func reviewShowsExactlyWhatGetsMovedWhenAnAncestorIsRefused() {
        let tree = sampleTree()
        var pile = DiscardPile()
        pile.add(FileTree.rootID)
        pile.add(tree.id("a/x.bin"))
        let policy = TrashSafetyPolicy(homePath: "/Users/me")
        let moved = MovedPaths()

        let plan = pile.plan(in: tree, policy: policy)
        let outcome = pile.moveToTrash(in: tree, policy: policy) { moved.append($0.path) }

        #expect(plan.moves == [tree.id("a/x.bin")], "a refused folder must not hide what is inside it")
        #expect(plan.refusals.map(\.id) == [FileTree.rootID])
        #expect(plan.bytes == 400, "refused items are not space to reclaim")
        #expect(moved.paths == ["/root/a/x.bin"])
        #expect(outcome.movedBytes == plan.bytes)
    }

    @Test func addingTwiceKeepsOneEntry() {
        let tree = sampleTree()
        var pile = DiscardPile()
        pile.add(tree.id("c.bin"))
        pile.add(tree.id("c.bin"))
        #expect(pile.items.count == 1)
    }

    @Test func movesOnlySafeItemsAndUpdatesTheTree() {
        let tree = sampleTree()
        var pile = DiscardPile()
        pile.add(tree.id("a"))
        pile.add(FileTree.rootID)
        let moved = MovedPaths()

        let outcome = pile.moveToTrash(in: tree, policy: TrashSafetyPolicy(homePath: "/Users/me")) { moved.append($0.path) }

        #expect(moved.paths == ["/root/a"])
        #expect(outcome.tree.root.allocatedSize == 400)
        #expect(outcome.failures.map(\.path) == ["/root"])
        #expect(outcome.movedBytes == 600)
        #expect(outcome.pile.items == [FileTree.rootID], "refused items stay in the pile for review")
    }

    @Test func aFailedMoveLeavesTheItemInTheTreeAndThePile() {
        let tree = sampleTree()
        var pile = DiscardPile()
        pile.add(tree.id("c.bin"))
        struct Denied: Error {}

        let outcome = pile.moveToTrash(in: tree, policy: TrashSafetyPolicy(homePath: "/Users/me")) { _ in throw Denied() }

        #expect(outcome.tree.root.allocatedSize == tree.root.allocatedSize)
        #expect(outcome.pile.items == [tree.id("c.bin")])
        #expect(outcome.failures.count == 1)
        #expect(outcome.movedBytes == 0)
    }

    @Test func itemsInsideAMovedFolderLeaveThePile() {
        let tree = sampleTree()
        var pile = DiscardPile()
        pile.add(tree.id("a/x.bin"))
        pile.add(tree.id("a"))

        let outcome = pile.moveToTrash(in: tree, policy: TrashSafetyPolicy(homePath: "/Users/me")) { _ in }

        #expect(outcome.pile.items.isEmpty)
        #expect(outcome.movedBytes == 600)
    }

    @Test(arguments: [
        "/", "/System", "/System/Library/Fonts", "/usr/bin/swift", "/bin/ls", "/sbin", "/Library", "/Applications",
        "/Users", "/Volumes", "/private", "/private/etc/hosts", "/Users/me", "/Users/me/Library", "/Users/me/Desktop",
        "/Users/me/Documents", "/Users/me/Downloads", "/Volumes/Backup", "/etc/hosts", "/var/db/x",
    ])
    func protectedPathsAreRefused(path: String) {
        #expect(TrashSafetyPolicy(homePath: "/Users/me").refusal(forPath: path) != nil)
    }

    @Test func policySeesThroughSymlinksAndCaseVariants() throws {
        let tmp = try TemporaryTree()
        defer { tmp.remove() }
        try tmp.folder("home/Documents")
        try tmp.file("home/Downloads/big.iso", bytes: 1)
        try FileManager.default.createSymbolicLink(
            at: tmp.root.appendingPathComponent("homelink"), withDestinationURL: tmp.root.appendingPathComponent("home"))
        try FileManager.default.createSymbolicLink(
            at: tmp.root.appendingPathComponent("parentlink"), withDestinationURL: tmp.root)
        let policy = TrashSafetyPolicy(homePath: tmp.root.path + "/home")

        #expect(policy.refusal(forPath: tmp.root.path + "/homelink/Documents") != nil)
        #expect(policy.refusal(forPath: tmp.root.path + "/HOME/documents") != nil)
        #expect(policy.refusal(forPath: tmp.root.path + "/parentlink/home") != nil)
        #expect(policy.refusal(forPath: tmp.root.path + "/homelink/Downloads/big.iso") == nil)
    }

    @Test func policySeesThroughSymlinksToUnreadableFolders() throws {
        let tmp = try TemporaryTree()
        defer { tmp.remove() }
        try tmp.folder("home/Documents")
        let home = tmp.root.path + "/home"
        try FileManager.default.createSymbolicLink(
            at: tmp.root.appendingPathComponent("homelink"), withDestinationURL: tmp.root.appendingPathComponent("home"))
        let policy = TrashSafetyPolicy(homePath: home)
        func lock(_ path: String, _ mode: Int) throws {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        }
        defer {
            try? lock(home, 0o755)
            try? lock(home + "/Documents", 0o755)
        }

        try lock(home + "/Documents", 0)
        #expect(policy.refusal(forPath: tmp.root.path + "/homelink/Documents") != nil, "the folder itself is unreadable")

        try lock(home + "/Documents", 0o755)
        try lock(home, 0)
        #expect(policy.refusal(forPath: tmp.root.path + "/homelink/Documents") != nil, "its parent cannot be searched")
    }

    @Test func aSymlinkItselfIsJudgedByItsOwnLocation() throws {
        let tmp = try TemporaryTree()
        defer { tmp.remove() }
        try tmp.folder("home/Documents")
        try FileManager.default.createSymbolicLink(
            at: tmp.root.appendingPathComponent("shortcut"), withDestinationURL: tmp.root.appendingPathComponent("home/Documents"))
        let policy = TrashSafetyPolicy(homePath: tmp.root.path + "/home")

        #expect(policy.refusal(forPath: tmp.root.path + "/shortcut") == nil, "trashing a link moves only the link")
    }

    @Test func realEverydayLocationsStayAllowed() {
        let home = NSHomeDirectory()
        let policy = TrashSafetyPolicy(homePath: home)
        #expect(policy.refusal(forPath: home + "/Library/Caches") == nil)
        #expect(policy.refusal(forPath: FileManager.default.temporaryDirectory.path + "/item") == nil)
    }

    @Test(arguments: [
        "/SYSTEM/Library", "/users/me/documents", "/Users/me/.ssh", "/Users/me/.Trash", "/Users/me/Library/Keychains",
        "/private/etc", "/private/var", "/private/var/db/x", "/private/tmp", "/private/var/root",
    ])
    func moreProtectedPaths(path: String) {
        #expect(TrashSafetyPolicy(homePath: "/Users/me").refusal(forPath: path) != nil)
    }

    @Test(arguments: [
        "/Applications/Old.app", "/Users/me/Downloads/big.iso", "/Users/me/Library/Caches/x", "/usr/local/share/thing",
        "/Library/Caches/y", "/Users/me/Documents/report.pdf", "/Volumes/Backup/old", "/private/tmp/item",
    ])
    func ordinaryPathsAreAllowed(path: String) {
        #expect(TrashSafetyPolicy(homePath: "/Users/me").refusal(forPath: path) == nil)
    }
}

private final class MovedPaths: @unchecked Sendable {
    var paths: [String] = []
    func append(_ path: String) { paths.append(path) }
}
