import Foundation
import Testing
@testable import DiskCore

@MainActor
@Suite("Developer caches scanner")
struct DeveloperCachesScannerTests {
    let dir: TemporaryDirectory
    let now = Date(timeIntervalSince1970: 1_793_804_400)

    /// Every location of the strict list, relative to the home folder.
    static let listed = [
        "Library/Developer/Xcode/DerivedData",
        "Library/Developer/Xcode/iOS DeviceSupport",
        "Library/Developer/Xcode/watchOS DeviceSupport",
        "Library/Developer/Xcode/tvOS DeviceSupport",
        "Library/Developer/Xcode/visionOS DeviceSupport",
        "Library/Developer/CoreSimulator/Caches",
        ".npm/_cacache",
        "Library/Caches/Homebrew",
        "Library/Caches/pip",
        "Library/Caches/Yarn",
        ".yarn/berry/cache",
        "Library/Caches/CocoaPods",
    ]

    init() throws {
        dir = try TemporaryDirectory()
    }

    private func scan() async throws -> [CleanCandidate] {
        try await DeveloperCachesScanner().scan(CleanEnvironment.testing(home: dir.url, now: now))
    }

    private func url(_ path: String) -> URL {
        dir.url.appending(path: path).canonical
    }

    /// Sets the modification date of `path` (and, when it is a folder, of everything inside it).
    private func age(_ path: String, days: Double) throws {
        let date = now.addingTimeInterval(-days * 86_400)
        let root = dir.url.appending(path: path)
        var items = [root]
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            items += enumerator.compactMap { $0 as? URL }
        }
        // Deepest first, so setting a child's date doesn't bump its folder's date afterwards.
        for item in items.sorted(by: { $0.path.count > $1.path.count }) {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: item.path)
        }
    }

    // MARK: - Strict list

    @Test("Every location of the strict list is found when present, sized as the whole folder")
    func everyListedLocation() async throws {
        for (index, path) in Self.listed.enumerated() {
            try dir.file("\(path)/item/data.bin", bytes: index + 1)
        }

        let candidates = try await scan()

        #expect(Set(candidates.map(\.url)) == Set(Self.listed.map(url)))
        for (index, path) in Self.listed.enumerated() {
            let candidate = try #require(candidates.first { $0.url == url(path) })
            #expect(candidate.bytes == Int64(index + 1))
            #expect(!candidate.detail.isEmpty)
            #expect(candidate.isTickedByDefault == nil)   // follows Safe to clear: ticked
        }
        #expect(DeveloperCachesScanner().kind == .developerCaches)
        #expect(SuggestionKind.developerCaches.group == .safe)
    }

    @Test("Folders that aren't on the list are never found, even next to listed ones")
    func lookalikesIgnored() async throws {
        try dir.file("Library/Caches/SomethingElse/data.bin", bytes: 10)
        try dir.file("Library/Caches/com.apple.Safari/data.bin", bytes: 10)
        try dir.file("Library/Developer/Xcode/Archives/App.xcarchive/data.bin", bytes: 10)
        try dir.file("Library/Developer/CoreSimulator/Devices/data.bin", bytes: 10)
        try dir.file(".npm/_logs/data.bin", bytes: 10)
        try dir.file("Library/Caches/pip-tools/data.bin", bytes: 10)
        try dir.file("Library/Caches/Homebrew/downloads/data.bin", bytes: 4)

        let candidates = try await scan()

        #expect(candidates.map(\.url) == [url("Library/Caches/Homebrew")])
    }

    @Test("A listed location that is a link, a file or empty is skipped")
    func linksFilesAndEmptySkipped() async throws {
        let target = try dir.folder("Elsewhere/RealFolder")
        try dir.file("Elsewhere/RealFolder/precious.bin", bytes: 20)
        try dir.folder("Library/Developer/Xcode")
        try FileManager.default.createSymbolicLink(
            at: dir.url.appending(path: "Library/Developer/Xcode/DerivedData"), withDestinationURL: target)
        try dir.file("Library/Caches/pip", bytes: 5)   // a file, not a folder
        try dir.folder("Library/Caches/Homebrew")      // empty
        try dir.folder("Library/Caches/Yarn/empty/inside")   // only empty folders: 0 bytes

        let candidates = try await scan()

        #expect(candidates.isEmpty)
    }

    @Test("Nothing present: nothing found")
    func nothingPresent() async throws {
        #expect(try await scan().isEmpty)
    }

    // MARK: - node_modules

    @Test("node_modules of a project untouched for 6 months is shown, never ticked")
    func oldProjectShownUnticked() async throws {
        try dir.file("Projects/old-app/package.json", bytes: 1)
        try dir.file("Projects/old-app/node_modules/dep/index.js", bytes: 30)
        try age("Projects/old-app", days: 200)

        let candidates = try await scan()

        let candidate = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(candidate.url == url("Projects/old-app/node_modules"))
        #expect(candidate.bytes == 30)
        #expect(candidate.isTickedByDefault == false)
        let since = now.addingTimeInterval(-200 * 86_400).formatted(date: .abbreviated, time: .omitted)
        #expect(candidate.detail == "Project untouched since \(since)")
    }

    @Test("A project touched within 6 months keeps its node_modules out of the list")
    func recentProjectNotShown() async throws {
        try dir.file("Documents/web/package.json", bytes: 1)
        try dir.file("Documents/web/src/main.js", bytes: 1)
        try dir.file("Documents/web/node_modules/dep/index.js", bytes: 30)
        try age("Documents/web", days: 400)
        try age("Documents/web/src", days: 10)   // one recent child is enough
        // node_modules itself being recent never makes the project count as touched, nor the reverse.
        try age("Documents/web/node_modules", days: 400)

        #expect(try await scan().isEmpty)
    }

    @Test("A recently changed node_modules doesn't make an old project count as touched")
    func recentNodeModulesIgnored() async throws {
        try dir.file("Developer/tool/package.json", bytes: 1)
        try dir.file("Developer/tool/node_modules/dep/index.js", bytes: 8)
        try age("Developer/tool", days: 300)
        try age("Developer/tool/node_modules", days: 1)

        let candidates = try await scan()

        #expect(candidates.map(\.url) == [url("Developer/tool/node_modules")])
    }

    @Test("A project with only node_modules uses its own date; 6 months means 182 days")
    func onlyNodeModulesAndThreshold() async throws {
        try dir.file("code/bare/node_modules/dep/index.js", bytes: 3)
        try dir.file("src/edge/package.json", bytes: 1)
        try dir.file("src/edge/node_modules/dep/index.js", bytes: 3)
        try age("code/bare", days: 183)
        try age("src/edge", days: 181)

        let candidates = try await scan()

        #expect(candidates.map(\.url) == [url("code/bare/node_modules")])
    }

    @Test("node_modules nested inside node_modules isn't reported separately")
    func nestedNotReported() async throws {
        try dir.file("Desktop/site/index.html", bytes: 1)
        try dir.file("Desktop/site/node_modules/a/node_modules/b/index.js", bytes: 5)
        try age("Desktop/site", days: 365)

        let candidates = try await scan()

        #expect(candidates.map(\.url) == [url("Desktop/site/node_modules")])
        #expect(candidates.first?.bytes == 5)
    }

    @Test("node_modules outside the scanned roots is never found")
    func outsideRootsIgnored() async throws {
        try dir.file("Library/old/package.json", bytes: 1)
        try dir.file("Library/old/node_modules/dep/index.js", bytes: 5)
        try dir.file("Other/old/package.json", bytes: 1)
        try dir.file("Other/old/node_modules/dep/index.js", bytes: 5)
        try age("Library/old", days: 365)
        try age("Other/old", days: 365)

        #expect(try await scan().isEmpty)
    }

    @Test("Scanning only reads: nothing is moved or deleted")
    func readOnly() async throws {
        try dir.file("Library/Caches/CocoaPods/data.bin", bytes: 5)
        try dir.file("Projects/old/node_modules/dep/index.js", bytes: 5)
        try age("Projects/old", days: 365)

        let candidates = try await scan()

        #expect(candidates.count == 2)
        #expect(FileManager.default.fileExists(atPath: url("Library/Caches/CocoaPods/data.bin").path))
        #expect(FileManager.default.fileExists(atPath: url("Projects/old/node_modules/dep/index.js").path))
    }
}
