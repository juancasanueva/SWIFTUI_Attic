import Foundation
import Testing
@testable import DiskCore

/// root/ a(600 = x:400 + y:200)  b(300)  c.bin(100)
func sampleTree() -> FileTree {
    let root = RawDirectory(name: "root")
    let a = RawDirectory(name: "a")
    a.entries = [
        .init(name: "x.bin", kind: .file, allocatedSize: 400, logicalSize: 390, modified: 1),
        .init(name: "y.txt", kind: .file, allocatedSize: 200, logicalSize: 190, modified: 2),
    ]
    let b = RawDirectory(name: "b.app", kind: .package)
    b.entries = [.init(name: "z", kind: .file, allocatedSize: 300, logicalSize: 290, modified: 3)]
    root.subdirectories = [b, a]
    root.entries = [.init(name: "c.bin", kind: .file, allocatedSize: 100, logicalSize: 90, modified: 4)]
    return FileTree(rootPath: "/root", rootDirectory: root, warnings: [ScanWarning(path: "/root/a/x.bin", message: "m")])
}

extension FileTree {
    func id(_ path: String) -> NodeID {
        var current = FileTree.rootID
        for part in path.split(separator: "/") {
            current = children(of: current).first { self[$0].name == part }!
        }
        return current
    }
}

@Suite struct FileTreeTests {
    @Test func removingUpdatesEveryAncestor() {
        let tree = sampleTree()
        let x = tree.id("a/x.bin")

        let updated = tree.removing([x])

        #expect(updated[tree.id("a")].allocatedSize == 200)
        #expect(updated.root.allocatedSize == 600)
        #expect(updated.root.fileCount == 3)
        #expect(updated.children(of: tree.id("a")).map { updated[$0].name } == ["y.txt"])
        #expect(!updated.contains(x))
        #expect(tree.contains(x), "the original tree stays untouched")
    }

    @Test func removingReordersSiblingsThatShrank() {
        let tree = sampleTree()

        let updated = tree.removing([tree.id("a/x.bin")])

        #expect(updated.children(of: FileTree.rootID).map { updated[$0].name } == ["b.app", "a", "c.bin"])
    }

    @Test func removingAFolderCountsAndHidesItsContents() {
        let tree = sampleTree()
        let a = tree.id("a")
        let x = tree.id("a/x.bin")

        let updated = tree.removing([a])

        #expect(updated.root.folderCount == 1)
        #expect(updated.root.fileCount == 2)
        #expect(!updated.contains(x))
        #expect(updated.warnings.isEmpty, "warnings inside a removed folder go away with it")
    }

    @Test func nodesAreFoundByAbsolutePath() {
        let tree = sampleTree()
        #expect(tree.node(atPath: "/root") == FileTree.rootID)
        #expect(tree.node(atPath: "/root/a/x.bin") == tree.id("a/x.bin"))
        #expect(tree.node(atPath: "/root/a/missing") == nil)
        #expect(tree.node(atPath: "/rootless/a") == nil)
    }

    @Test func rootCannotBeRemoved() {
        let tree = sampleTree()
        #expect(tree.removing([FileTree.rootID]).root.allocatedSize == tree.root.allocatedSize)
    }

    @Test func removingParentAndChildTogetherSubtractsOnce() {
        let tree = sampleTree()
        let updated = tree.removing([tree.id("a"), tree.id("a/x.bin")])
        #expect(updated.root.allocatedSize == 400)
    }
}
