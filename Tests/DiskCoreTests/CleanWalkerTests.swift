import Foundation
import Testing
@testable import DiskCore

@Suite("Smart Clean: walker shared by the scanners")
struct CleanWalkerTests {
    let dir: TemporaryDirectory

    init() throws {
        dir = try TemporaryDirectory()
    }

    @Test("The walker visits regular files of a minimum size, never hidden items or package contents")
    func walker() throws {
        try dir.file("Documents/big.bin", bytes: 50)
        try dir.file("Documents/small.bin", bytes: 5)
        try dir.file("Documents/.hidden/big.bin", bytes: 50)
        try dir.file("Documents/.dot.bin", bytes: 50)
        try dir.file("Documents/Tool.app/Contents/big.bin", bytes: 50)
        try dir.file("Documents/deep/er/big2.bin", bytes: 60)

        var seen: [String: Int64] = [:]
        try CleanWalker.regularFiles(in: [dir.url.appending(path: "Documents")], minimumSize: 10) { url, size in
            seen[url.lastPathComponent] = size
        }

        #expect(seen == ["big.bin": 50, "big2.bin": 60])
    }

    @Test("Folders named like a target are found without entering them or hidden folders")
    func walkerDirectories() throws {
        try dir.folder("Projects/web/node_modules/dep/node_modules")
        try dir.folder("Projects/.cache/node_modules")
        try dir.folder("Projects/a/b/c/d/e/f/node_modules")   // too deep

        let found = CleanWalker.directories(named: "node_modules", in: [dir.url.appending(path: "Projects")], maxDepth: 4)

        #expect(found.map { $0.deletingLastPathComponent().lastPathComponent } == ["web"])
    }

    @Test("Sizes: a file's own size, a folder's whole tree")
    func sizes() throws {
        let file = try dir.file("f.bin", bytes: 12)
        try dir.file("d/a", bytes: 3)
        try dir.file("d/e/b", bytes: 4)
        #expect(CleanWalker.size(of: file) == 12)
        #expect(CleanWalker.size(of: dir.url.appending(path: "d")) == 7)
    }
}
