import Foundation
import Testing
@testable import DiskCore

/// A throwaway directory tree on the real file system, outside the repository.
struct TemporaryTree {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskCoreTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func file(_ path: String, bytes: Int) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    func folder(_ path: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("locked").path)
        try? FileManager.default.removeItem(at: root)
    }
}

/// Allocated bytes reported by the file system, the value the scanner has to match.
func allocatedSize(_ url: URL) throws -> Int64 {
    var info = stat()
    #expect(lstat(url.path, &info) == 0)
    return Int64(info.st_blocks) * 512
}

@Suite struct FileScannerTests {
    @Test func aggregatesSizesAndCountsUpTheTree() async throws {
        let tmp = try TemporaryTree()
        defer { tmp.remove() }
        try tmp.file("a/one.bin", bytes: 40_000)
        try tmp.file("a/b/two.bin", bytes: 90_000)
        try tmp.file("three.bin", bytes: 10_000)

        let tree = try await FileScanner().scan(root: tmp.root)

        let expected = try allocatedSize(tmp.root.appendingPathComponent("a/one.bin"))
            + allocatedSize(tmp.root.appendingPathComponent("a/b/two.bin"))
            + allocatedSize(tmp.root.appendingPathComponent("three.bin"))
        #expect(tree.root.allocatedSize == expected)
        #expect(tree.root.fileCount == 3)
        #expect(tree.root.folderCount == 2)
        #expect(tree.root.logicalSize == 140_000)
        #expect(tree.warnings.isEmpty)
    }

    @Test func childrenAreSortedByDescendingAllocatedSize() async throws {
        let tmp = try TemporaryTree()
        defer { tmp.remove() }
        try tmp.file("small.bin", bytes: 8_192)
        try tmp.file("big/inner.bin", bytes: 900_000)
        try tmp.file("mid.bin", bytes: 100_000)

        let tree = try await FileScanner().scan(root: tmp.root)

        #expect(tree.children(of: FileTree.rootID).map { tree[$0].name } == ["big", "mid.bin", "small.bin"])
    }

    @Test func pathsAreRebuiltFromParents() async throws {
        let tmp = try TemporaryTree()
        defer { tmp.remove() }
        try tmp.file("a/b/c.bin", bytes: 10)

        let tree = try await FileScanner().scan(root: tmp.root)

        let a = try #require(tree.children(of: FileTree.rootID).first)
        let b = try #require(tree.children(of: a).first)
        let c = try #require(tree.children(of: b).first)
        #expect(tree.path(of: c) == tmp.root.path + "/a/b/c.bin")
        #expect(tree.ancestors(of: c) == [FileTree.rootID, a, b, c])
        #expect(tree[c].kind == .file)
        #expect(tree[b].kind == .folder)
    }

    @Test func hardLinksAreCountedOnce() async throws {
        let tmp = try TemporaryTree()
        defer { tmp.remove() }
        try tmp.file("original.bin", bytes: 500_000)
        try FileManager.default.linkItem(
            at: tmp.root.appendingPathComponent("original.bin"),
            to: tmp.root.appendingPathComponent("link.bin"))

        let tree = try await FileScanner().scan(root: tmp.root)

        #expect(tree.root.allocatedSize == (try allocatedSize(tmp.root.appendingPathComponent("original.bin"))))
        #expect(tree.root.logicalSize == 500_000)
        #expect(tree.root.fileCount == 2)
    }

    @Test func symlinksAreNotFollowed() async throws {
        let tmp = try TemporaryTree()
        defer { tmp.remove() }
        try tmp.file("real/data.bin", bytes: 300_000)
        try FileManager.default.createSymbolicLink(
            at: tmp.root.appendingPathComponent("alias"),
            withDestinationURL: tmp.root.appendingPathComponent("real"))

        let tree = try await FileScanner().scan(root: tmp.root)

        let alias = try #require(tree.children(of: FileTree.rootID).first { tree[$0].name == "alias" })
        #expect(tree[alias].kind == .symlink)
        #expect(tree.children(of: alias).isEmpty)
        #expect(tree.root.fileCount == 2)
    }

    @Test func unreadableFolderBecomesAWarningOnItsAncestors() async throws {
        let tmp = try TemporaryTree()
        defer { tmp.remove() }
        try tmp.file("locked/hidden.bin", bytes: 4_096)
        try tmp.file("open.bin", bytes: 4_096)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: tmp.root.appendingPathComponent("locked").path)

        let tree = try await FileScanner().scan(root: tmp.root)

        let locked = try #require(tree.children(of: FileTree.rootID).first { tree[$0].name == "locked" })
        #expect(tree[locked].isUnreadable)
        #expect(tree[locked].warningCount == 1)
        #expect(tree.root.warningCount == 1)
        #expect(tree.warnings.map(\.path) == [tmp.root.path + "/locked"])
        #expect(tree.root.fileCount == 1)
    }

    @Test func missingRootThrows() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
        await #expect(throws: FileScanner.Failure.self) {
            _ = try await FileScanner().scan(root: missing)
        }
    }

    @Test func manyEntriesSurviveBufferBoundaries() async throws {
        let tmp = try TemporaryTree()
        defer { tmp.remove() }
        for index in 0..<3_000 {
            try tmp.file("dir\(index % 7)/a-file-with-quite-a-long-name-\(index).bin", bytes: 1)
        }

        let tree = try await FileScanner().scan(root: tmp.root)

        #expect(tree.root.fileCount == 3_000)
        #expect(tree.root.folderCount == 7)
    }

    @Test func cancellationStopsTheScan() async throws {
        let tmp = try TemporaryTree()
        defer { tmp.remove() }
        for index in 0..<200 { try tmp.file("d\(index)/f.bin", bytes: 1) }

        let task = Task.detached { try await FileScanner().scan(root: tmp.root) }
        task.cancel()

        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func aMountedVolumeInsideTheScanIsNotEntered() async throws {
        let tmp = try TemporaryTree()
        defer { tmp.remove() }
        try tmp.file("outside.bin", bytes: 4_096)
        try tmp.folder("mount")
        let image = tmp.root.path + "/volume.dmg"
        let mountPoint = tmp.root.path + "/mount"
        try hdiutil("create", "-quiet", "-size", "8m", "-fs", "APFS", "-volname", "Probe", image)
        try hdiutil("attach", "-quiet", "-nobrowse", "-mountpoint", mountPoint, image)
        defer { try? hdiutil("detach", "-quiet", "-force", mountPoint) }
        try Data(repeating: 0x41, count: 2_000_000).write(to: URL(fileURLWithPath: mountPoint + "/inside.bin"))

        let tree = try await FileScanner().scan(root: tmp.root)

        let mount = try #require(tree.children(of: FileTree.rootID).first { tree[$0].name == "mount" })
        #expect(tree.children(of: mount).isEmpty)
        #expect(tree[mount].allocatedSize == 0)
        #expect(tree.root.fileCount == 2, "outside.bin and volume.dmg only")
    }

    @Test func foldersOnOtherDevicesAreNotEntered() {
        let boundary = VolumeBoundary.forRoot(path: "/Users/me", device: 5, dataVolumeDevice: 9)
        #expect(boundary.allows(path: "/Users/me/Documents", device: 5))
        #expect(!boundary.allows(path: "/Users/me/share", device: 9))
    }

    @Test func startupDiskFollowsFirmlinksWithoutDoubleCounting() {
        let boundary = VolumeBoundary.forRoot(path: "/", device: 5, dataVolumeDevice: 9)
        #expect(boundary.allows(path: "/Users", device: 9))
        #expect(!boundary.allows(path: "/Volumes", device: 5))
        #expect(!boundary.allows(path: "/System/Volumes", device: 5))
        #expect(!boundary.allows(path: "/mnt/backup", device: 12))
        #expect(!boundary.allows(path: "/.vol", device: 5), "virtual paths would expose the same files again")
    }

    @Test func packagesAreRecognizedByExtension() {
        #expect(PackageClassifier.kind(ofFolderNamed: "Safari.app") == .package)
        #expect(PackageClassifier.kind(ofFolderNamed: "photos.v2") == .folder)
        #expect(PackageClassifier.kind(ofFolderNamed: ".app") == .folder)
    }

    @Test func reportsProgressWithFinalCounts() async throws {
        let tmp = try TemporaryTree()
        defer { tmp.remove() }
        try tmp.file("a/b.bin", bytes: 100)

        let box = ProgressBox()
        _ = try await FileScanner().scan(root: tmp.root) { box.value = $0 }

        #expect(box.value?.filesScanned == 1)
        #expect(box.value?.foldersScanned == 2)
    }
}

private func hdiutil(_ arguments: String...) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
}

private final class ProgressBox: @unchecked Sendable {
    var value: ScanProgress?
}
