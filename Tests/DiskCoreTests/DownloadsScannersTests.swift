import Foundation
import Testing
@testable import DiskCore

@Suite("Smart Clean: installers, Mail attachments, old downloads and screen recordings")
struct DownloadsScannersTests {
    let dir: TemporaryDirectory
    let now = Date(timeIntervalSince1970: 1_793_804_400)

    init() throws {
        dir = try TemporaryDirectory()
    }

    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    /// Creates a file whose creation and modification dates are `days` before `now`.
    @discardableResult
    private func file(_ path: String, bytes: Int = 1, daysOld days: Double = 0) throws -> URL {
        let url = try dir.file(path, bytes: bytes)
        try FileManager.default.setAttributes(
            [.creationDate: daysAgo(days), .modificationDate: daysAgo(days)], ofItemAtPath: url.path)
        return url
    }

    private func app(_ name: String, in folder: String = "Applications", bundleID: String? = nil) -> InstalledApp {
        InstalledApp(url: dir.url.appending(path: "\(folder)/\(name).app"), name: name, bundleID: bundleID)
    }

    /// A real-looking installer: a disk image ending in the UDIF "koly" trailer, or a flat
    /// package starting with the "xar!" header. Returns its size.
    @discardableResult
    private func installer(_ path: String) throws -> Int64 {
        let url = dir.url.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(count: 1_000)
        if url.pathExtension == "dmg" {
            var trailer = Data("koly".utf8)
            trailer.append(Data(count: 508))
            data.append(trailer)
        } else {
            data.replaceSubrange(0..<4, with: Data("xar!".utf8))
        }
        try data.write(to: url)
        return Int64(data.count)
    }

    private func paths(_ candidates: [CleanCandidate]) -> Set<String> {
        Set(candidates.map { $0.url.path.replacingOccurrences(of: dir.url.canonical.path + "/", with: "") })
    }

    private func abbreviated(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .omitted) }

    // MARK: - Installers

    @Test("A .dmg or .pkg in Downloads or Desktop whose name, without version and platform words, matches an installed app")
    func installers() async throws {
        let slackSize = try installer("Downloads/Slack-4.41.105-macOS.dmg")
        try installer("Desktop/Zoom_v2_universal_installer.pkg")
        try installer("Downloads/Firefox 132.0.dmg")              // Firefox isn't installed
        try file("Downloads/Slack-notes.txt")                     // not an installer
        try installer("Downloads/Nested/Slack-4.0.dmg")           // not directly in Downloads
        try installer("Documents/Slack-4.0.dmg")                  // not Downloads or Desktop
        let environment = CleanEnvironment.testing(home: dir.url, installedApps: [app("Slack"), app("zoom")])

        let found = try await InstallersScanner().scan(environment)

        #expect(InstallersScanner().kind == .installers)
        #expect(paths(found) == ["Downloads/Slack-4.41.105-macOS.dmg", "Desktop/Zoom_v2_universal_installer.pkg"])
        let slack = try #require(found.first { $0.url.lastPathComponent.hasPrefix("Slack") })
        #expect(slack.bytes == slackSize)
        #expect(slack.detail == "“Slack” is installed")
        #expect(found.first { $0.url.lastPathComponent.hasPrefix("Zoom") }?.detail == "“zoom” is installed")
    }

    @Test("Names shorter than 3 characters after normalizing never match")
    func installersShortNames() async throws {
        try installer("Downloads/Go-1.22-darwin-arm64.pkg")
        try installer("Downloads/X-2.dmg")
        let environment = CleanEnvironment.testing(home: dir.url, installedApps: [app("Go"), app("X")])

        #expect(try await InstallersScanner().scan(environment).isEmpty)
    }

    @Test("No installers when the matching app isn't installed, or the folders are missing")
    func installersNoApp() async throws {
        try installer("Downloads/Slack-4.41.105-macOS.dmg")
        #expect(try await InstallersScanner().scan(.testing(home: dir.url)).isEmpty)
        let empty = try TemporaryDirectory()
        #expect(try await InstallersScanner().scan(.testing(home: empty.url, installedApps: [app("Slack")])).isEmpty)
    }

    @Test("A .dmg or .pkg that isn't really an installer is never listed")
    func installersCheckTheFormat() async throws {
        try file("Downloads/Slack.dmg", bytes: 2_000)            // no disk image trailer
        try file("Downloads/Zoom.pkg", bytes: 2_000)             // no package header
        try installer("Desktop/Slack-2.dmg")
        try dir.folder("Desktop/Zoom-2.pkg/Contents")            // a package folder is fine
        let environment = CleanEnvironment.testing(home: dir.url, installedApps: [app("Slack"), app("Zoom")])

        let found = try await InstallersScanner().scan(environment)

        #expect(paths(found) == ["Desktop/Slack-2.dmg", "Desktop/Zoom-2.pkg"])
    }

    @Test("An installer only in iCloud (not downloaded) is never read or listed, so it isn't downloaded")
    func installersSkipICloudOnlyFiles() async throws {
        try installer("Desktop/Slack.dmg")
        try installer("Downloads/Zoom.dmg")
        let environment = CleanEnvironment.testing(home: dir.url, installedApps: [app("Slack"), app("Zoom")])
        let scanner = InstallersScanner(isDownloaded: { $0.lastPathComponent != "Slack.dmg" })

        let found = try await scanner.scan(environment)

        #expect(paths(found) == ["Downloads/Zoom.dmg"])
    }

    @Test("Only apps you installed count: not Apple's, not helpers outside the Applications folders")
    func installersOnlyForYourApps() async throws {
        try installer("Downloads/Notes.dmg")
        try installer("Downloads/Updater.pkg")
        try installer("Downloads/Slack.dmg")
        let environment = CleanEnvironment.testing(home: dir.url, installedApps: [
            app("Notes", bundleID: "com.apple.Notes"),
            app("Updater", in: "Library/Application Support/Vendor"),
            app("Slack", bundleID: "com.tinyspeck.slackmacgap"),
        ])

        let found = try await InstallersScanner().scan(environment)

        #expect(paths(found) == ["Downloads/Slack.dmg"])
    }

    // MARK: - Mail attachments

    private let mailDownloads = "Library/Containers/com.apple.mail/Data/Library/Mail Downloads"

    @Test("Each entry of Mail Downloads, sized whole, named after the first file inside")
    func mailAttachments() async throws {
        try file("\(mailDownloads)/A1B2/Invoice.pdf", bytes: 4)
        try file("\(mailDownloads)/A1B2/Zeta.txt", bytes: 2)
        try file("\(mailDownloads)/photo.jpg", bytes: 3)

        let found = try await MailAttachmentsScanner().scan(.testing(home: dir.url))

        #expect(MailAttachmentsScanner().kind == .mailAttachments)
        #expect(paths(found) == ["\(mailDownloads)/A1B2", "\(mailDownloads)/photo.jpg"])
        let folder = try #require(found.first { $0.url.lastPathComponent == "A1B2" })
        #expect(folder.bytes == 6)
        #expect(folder.detail == "Mail's copy of “Invoice.pdf”")
        #expect(found.first { $0.url.lastPathComponent == "photo.jpg" }?.detail == "Mail's copy of “photo.jpg”")
    }

    @Test("A missing or unreadable Mail Downloads folder is skipped silently")
    func mailAttachmentsUnreadable() async throws {
        #expect(try await MailAttachmentsScanner().scan(.testing(home: dir.url)).isEmpty)

        let folder = try dir.folder(mailDownloads)
        try file("\(mailDownloads)/photo.jpg")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        #expect(try await MailAttachmentsScanner().scan(.testing(home: dir.url)).isEmpty)
    }

    // MARK: - Old downloads

    @Test("Files in Downloads and its Tidy kind folders added over 90 days ago and not opened in 90 days")
    func oldDownloads() async throws {
        try file("Downloads/old.zip", bytes: 7, daysOld: 120)
        try file("Downloads/Videos/old.mp4", daysOld: 200)
        try file("Downloads/PDFs/old.pdf", daysOld: 100)
        try file("Downloads/recent.zip", daysOld: 10)
        try file("Downloads/opened.zip", daysOld: 120)
        try file("Downloads/Other Stuff/old.zip", daysOld: 120)   // not a kind folder
        try file("Downloads/Videos/Deeper/old.mp4", daysOld: 200) // not directly in a kind folder
        try file("Downloads/.hidden", daysOld: 120)
        try file("Downloads/movie.mp4.download", daysOld: 120)
        try file("Downloads/movie.crdownload", daysOld: 120)
        try file("Downloads/movie.part", daysOld: 120)
        let openedRecently = daysAgo(5)
        let environment = CleanEnvironment.testing(home: dir.url, lastOpened: { url in
            url.lastPathComponent == "opened.zip" ? openedRecently : nil
        })

        let found = try await OldDownloadsScanner(addedDate: { _ in nil }).scan(environment)

        #expect(OldDownloadsScanner().kind == .oldDownloads)
        #expect(paths(found) == ["Downloads/old.zip", "Downloads/Videos/old.mp4", "Downloads/PDFs/old.pdf"])
        let zip = try #require(found.first { $0.url.lastPathComponent == "old.zip" })
        #expect(zip.bytes == 7)
        #expect(zip.detail == "Downloaded \(abbreviated(daysAgo(120)))")
    }

    @Test("The date added to Downloads wins over the creation date; opened over 90 days ago still counts")
    func oldDownloadsAddedDate() async throws {
        try file("Downloads/created-long-ago.zip", daysOld: 400)   // but added recently
        try file("Downloads/added-long-ago.zip", daysOld: 1)       // but added long ago
        try file("Downloads/opened-long-ago.zip", daysOld: 400)
        let added: [String: Date] = [
            "created-long-ago.zip": daysAgo(3), "added-long-ago.zip": daysAgo(95), "opened-long-ago.zip": daysAgo(400),
        ]
        let openedLongAgo = daysAgo(91)
        let environment = CleanEnvironment.testing(home: dir.url, lastOpened: { url in
            url.lastPathComponent == "opened-long-ago.zip" ? openedLongAgo : nil
        })

        let found = try await OldDownloadsScanner(addedDate: { added[$0.lastPathComponent] }).scan(environment)

        #expect(paths(found) == ["Downloads/added-long-ago.zip", "Downloads/opened-long-ago.zip"])
        #expect(found.first { $0.url.lastPathComponent == "added-long-ago.zip" }?.detail
            == "Downloaded \(abbreviated(daysAgo(95)))")
    }

    // MARK: - Screen recordings

    @Test("Screen recordings (Spotlight or name) in the usual folders, older than 30 days")
    func screenRecordings() async throws {
        try file("Desktop/Screen Recording 2026-01-01 at 10.00.00.mov", bytes: 9, daysOld: 60)
        try file("Movies/grabación de pantalla 2026-01-01.mp4", daysOld: 45)
        try file("Documents/capture.mov", daysOld: 40)            // Spotlight says it's a capture
        try file("Downloads/Screen Recording old.MOV", daysOld: 31)
        try file("Desktop/Holiday.mov", daysOld: 60)              // not a recording
        try file("Desktop/Screen Recording recent.mov", daysOld: 5)
        try file("Desktop/Screen Recording notes.txt", daysOld: 60)
        try file("Pictures/Screen Recording 1.mov", daysOld: 60)  // not a scanned folder
        try file("Desktop/Sub/Screen Recording 2.mov", daysOld: 60)
        let environment = CleanEnvironment.testing(home: dir.url, isScreenCapture: { $0.lastPathComponent == "capture.mov" })

        let found = try await ScreenRecordingsScanner(customLocation: { nil }).scan(environment)

        #expect(ScreenRecordingsScanner().kind == .screenRecordings)
        #expect(paths(found) == [
            "Desktop/Screen Recording 2026-01-01 at 10.00.00.mov", "Movies/grabación de pantalla 2026-01-01.mp4",
            "Documents/capture.mov", "Downloads/Screen Recording old.MOV",
        ])
        let first = try #require(found.first { $0.url.lastPathComponent.hasPrefix("Screen Recording 2026") })
        #expect(first.bytes == 9)
        #expect(first.detail == "Recorded \(abbreviated(daysAgo(60)))")
    }

    @Test("The custom screenshot location is scanned too, once even when it's a usual folder")
    func screenRecordingsCustomLocation() async throws {
        try file("Captures/Screen Recording 1.mov", daysOld: 60)
        try file("Desktop/Screen Recording 2.mov", daysOld: 60)
        let captures = dir.url.appending(path: "Captures")
        let desktop = dir.url.appending(path: "Desktop")

        let custom = try await ScreenRecordingsScanner(customLocation: { captures }).scan(.testing(home: dir.url))
        #expect(paths(custom) == ["Captures/Screen Recording 1.mov", "Desktop/Screen Recording 2.mov"])

        let same = try await ScreenRecordingsScanner(customLocation: { desktop }).scan(.testing(home: dir.url))
        #expect(same.count == 1)
    }
}
