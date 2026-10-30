import Foundation
import Testing
@testable import DiskCore

@Suite struct TrashTests {
    private let policy = TrashSafetyPolicy(homePath: "/Users/me")

    @Test func aFolderAbsorbsItemsInsideIt() {
        let tree = sampleTree()

        let plan = TrashPlan(items: [tree.id("a/x.bin"), tree.id("a"), tree.id("c.bin")], in: tree, policy: policy)

        #expect(plan.moves == [tree.id("a"), tree.id("c.bin")])
        #expect(plan.bytes == 700)
        #expect(plan.refusals.isEmpty)
    }

    @Test func aRefusedFolderDoesNotShelterItemsInsideIt() {
        let tree = sampleTree()
        let moved = MovedPaths()

        let plan = TrashPlan(items: [FileTree.rootID, tree.id("a/x.bin")], in: tree, policy: policy)
        let outcome = plan.execute(in: tree) { moved.append($0.path) }

        #expect(plan.moves == [tree.id("a/x.bin")])
        #expect(plan.refusals.map(\.id) == [FileTree.rootID])
        #expect(plan.bytes == 400, "refused items are not space to reclaim")
        #expect(moved.paths == ["/root/a/x.bin"])
        #expect(outcome.movedBytes == plan.bytes)
    }

    @Test func repeatedItemsCountOnce() {
        let tree = sampleTree()
        let plan = TrashPlan(items: [tree.id("c.bin"), tree.id("c.bin")], in: tree, policy: policy)
        #expect(plan.moves == [tree.id("c.bin")])
        #expect(plan.bytes == 100)
    }

    @Test func movesOnlySafeItemsAndUpdatesTheTree() {
        let tree = sampleTree()
        let moved = MovedPaths()

        let outcome = TrashPlan(items: [tree.id("a"), FileTree.rootID], in: tree, policy: policy)
            .execute(in: tree) { moved.append($0.path) }

        #expect(moved.paths == ["/root/a"])
        #expect(outcome.tree.root.allocatedSize == 400)
        #expect(outcome.failures.map(\.path) == ["/root"])
        #expect(outcome.movedBytes == 600)
    }

    @Test func aFailedMoveLeavesTheItemInTheTree() {
        let tree = sampleTree()
        struct Denied: Error {}

        let outcome = TrashPlan(items: [tree.id("c.bin")], in: tree, policy: policy)
            .execute(in: tree) { _ in throw Denied() }

        #expect(outcome.tree.root.allocatedSize == tree.root.allocatedSize)
        #expect(outcome.tree.contains(tree.id("c.bin")))
        #expect(outcome.failures.count == 1)
        #expect(outcome.movedBytes == 0)
    }

    @Test func itemsAlreadyRemovedAreIgnored() {
        let tree = sampleTree()
        let updated = tree.removing([tree.id("a")])

        let plan = TrashPlan(items: [tree.id("a/x.bin")], in: updated, policy: policy)

        #expect(plan.moves.isEmpty)
        #expect(plan.refusals.isEmpty)
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
