import Foundation
import Testing
@testable import DiskCore

@MainActor
@Suite("Duplicates scanner")
struct DuplicatesScannerTests {
    let dir: TemporaryDirectory
    let scanner = DuplicatesScanner(minimumSize: 10)

    init() throws {
        dir = try TemporaryDirectory()
    }

    /// Writes `data` at `relativePath` under the fake home and returns its canonical URL.
    @discardableResult
    private func write(_ relativePath: String, _ data: Data, modified: Date? = nil) throws -> URL {
        let url = dir.url.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url.canonical
    }

    private func content(_ seed: UInt8, count: Int = 100) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0) &+ seed })
    }

    private func scan(lastOpened: @escaping @Sendable (URL) -> Date? = { _ in nil }) async throws -> [CleanCandidate] {
        let environment = CleanEnvironment.testing(home: dir.url, lastOpened: lastOpened)
        return try await scanner.scan(environment).sorted { $0.url.path < $1.url.path }
    }

    @Test("Kind is duplicates, in Safe to clear")
    func kind() {
        #expect(scanner.kind == .duplicates)
        #expect(scanner.kind.group == .safe)
    }

    @Test("Identical files across folders: the copy opened last is kept, the others are reported")
    func identicalAcrossFolders() async throws {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let documents = try write("Documents/report.pdf", content(1), modified: old.addingTimeInterval(500))
        let downloads = try write("Downloads/report.pdf", content(1), modified: old)
        let desktop = try write("Desktop/report copy.pdf", content(1), modified: old.addingTimeInterval(900))
        let openedPath = downloads.path

        let found = try await scan(lastOpened: { $0.canonical.path == openedPath ? old.addingTimeInterval(1_000) : nil })

        #expect(found.map(\.url) == [desktop, documents])
        #expect(found.map(\.detail) == ["Copy of ~/Downloads/report.pdf", "Copy of ~/Downloads/report.pdf"])
        #expect(found.map(\.bytes) == [100, 100])
        #expect(found.map(\.keptCopy) == [downloads.canonical, downloads.canonical])
    }

    @Test("With no open date known, the most recently modified copy is kept")
    func keepsLastModified() async throws {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let older = try write("Documents/a/photo.jpg", content(2, count: 40), modified: old)
        try write("Pictures/photo.jpg", content(2, count: 40), modified: old.addingTimeInterval(60))

        let found = try await scan()

        #expect(found.map(\.url) == [older])
        #expect(found.map(\.detail) == ["Copy of ~/Pictures/photo.jpg"])
        #expect(found.map(\.bytes) == [40])
    }

    @Test("Same dates: the shortest path is kept, then alphabetical order")
    func tieBreakers() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let longer = try write("Music/deep/folder/clip.mov", content(3), modified: date)
        let second = try write("Downloads/clip.mov", content(3), modified: date)
        try write("Documents/clip.mov", content(3), modified: date)

        let found = try await scan()

        #expect(found.map(\.url) == [second, longer])
        #expect(found.map(\.detail) == ["Copy of ~/Documents/clip.mov", "Copy of ~/Documents/clip.mov"])
        #expect(found.map(\.bytes) == [100, 100])
    }

    @Test("Same size but different contents, even with the same first 64 KB, are not duplicates")
    func differentContents() async throws {
        try write("Documents/one.bin", content(4))
        try write("Downloads/two.bin", content(5))
        var head = Data(repeating: 7, count: 70_000)
        try write("Documents/big-a.bin", head)
        head[69_999] = 8
        try write("Downloads/big-b.bin", head)

        #expect(try await scan().isEmpty)
    }

    @Test("Large identical files beyond the first 64 KB are found")
    func largeIdentical() async throws {
        let data = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 / 7) })
        let copy = try write("Documents/archive.zip", data, modified: Date(timeIntervalSince1970: 1_700_000_000))
        try write("Downloads/archive.zip", data, modified: Date(timeIntervalSince1970: 1_700_000_100))

        let found = try await scan()

        #expect(found.map(\.url) == [copy])
        #expect(found.map(\.detail) == ["Copy of ~/Downloads/archive.zip"])
        #expect(found.map(\.bytes) == [200_000])
    }

    @Test("Files below the minimum size are not reported")
    func belowMinimum() async throws {
        try write("Documents/tiny.txt", content(6, count: 9))
        try write("Downloads/tiny.txt", content(6, count: 9))

        #expect(try await scan().isEmpty)
    }

    @Test("Hidden items and package contents are ignored")
    func hiddenAndPackages() async throws {
        try write("Documents/original.bin", content(7))
        try write("Documents/.hidden.bin", content(7))
        try write("Documents/.secret/copy.bin", content(7))
        try write("Downloads/Tool.app/Contents/Resources/copy.bin", content(7))
        try write("Library/copy.bin", content(7))

        #expect(try await scan().isEmpty)
    }

    @Test("Hard links to the same file are not duplicates of each other")
    func hardLinks() async throws {
        let original = try write("Documents/linked.bin", content(8))
        let link = dir.url.appending(path: "Downloads/linked.bin")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: original, to: link)

        #expect(try await scan().isEmpty)
    }

    @Test("Missing user folders are skipped")
    func missingFolders() async throws {
        #expect(try await scan().isEmpty)
    }
}
