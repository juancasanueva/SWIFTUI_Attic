import Foundation
import Testing
@testable import DiskCore

@MainActor
@Suite("Library scanners")
struct LibraryScannersTests {
    let dir: TemporaryDirectory
    let now = Date(timeIntervalSince1970: 1_793_804_400)

    init() throws {
        dir = try TemporaryDirectory()
    }

    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    /// Sets an item's modification date, `days` before the test's "now".
    private func touch(_ url: URL, daysAgo days: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: daysAgo(days)], ofItemAtPath: url.path)
    }

    /// `lastOpened` answers by file name, so it doesn't depend on /var vs /private/var.
    private func environment(
        installed: [String] = [], opened: [String: Date] = [:]
    ) -> CleanEnvironment {
        let apps = installed.map { InstalledApp(url: URL(filePath: "/Applications/\($0).app"), name: $0, bundleID: $0) }
        return CleanEnvironment.testing(
            home: dir.url, now: now, installedApps: apps, lastOpened: { opened[$0.lastPathComponent] })
    }

    private func names(_ candidates: [CleanCandidate]) -> Set<String> {
        Set(candidates.map(\.url.lastPathComponent))
    }

    // MARK: - Big files

    @Test("Big files: regular files at or above the threshold, in Your call")
    func bigFilesThreshold() async throws {
        try dir.file("Movies/at.mov", bytes: 100)
        try dir.file("Documents/deep/above.bin", bytes: 150)
        try dir.file("Desktop/below.bin", bytes: 99)
        try dir.file("Library/outside.bin", bytes: 500)   // not a user folder

        let scanner = BigFilesScanner(minimumSize: 100)
        let found = try await scanner.scan(environment())

        #expect(scanner.kind == .bigFiles && scanner.kind.group == .yourCall)
        #expect(names(found) == ["at.mov", "above.bin"])
        #expect(found.first { $0.url.lastPathComponent == "above.bin" }?.bytes == 150)
    }

    @Test("Big files: the default threshold is 1 GB")
    func bigFilesDefault() {
        #expect(BigFilesScanner().minimumSize == 1_000_000_000)
    }

    @Test("Big files: hidden files and files inside packages are never listed")
    func bigFilesHiddenAndPackages() async throws {
        try dir.file("Documents/.hidden.bin", bytes: 200)
        try dir.file("Documents/.cache/big.bin", bytes: 200)
        try dir.file("Documents/Tool.app/Contents/big.bin", bytes: 200)
        try dir.file("Documents/kept.bin", bytes: 200)

        let found = try await BigFilesScanner(minimumSize: 100).scan(environment())

        #expect(names(found) == ["kept.bin"])
    }

    @Test("Big files: the detail says the size and when it was last opened, or never")
    func bigFilesDetail() async throws {
        try dir.file("Movies/opened.mov", bytes: 200)
        try dir.file("Movies/never.mov", bytes: 300)
        let opened = daysAgo(40)

        let found = try await BigFilesScanner(minimumSize: 100).scan(environment(opened: ["opened.mov": opened]))

        let detail = Dictionary(uniqueKeysWithValues: found.map { ($0.url.lastPathComponent, $0.detail) })
        #expect(detail["opened.mov"] == "\(Int64(200).fileSizeText) · opened \(opened.formatted(date: .abbreviated, time: .omitted))")
        #expect(detail["never.mov"] == "\(Int64(300).fileSizeText) · last opened unknown")
    }

    @Test("Big files: missing user folders are skipped")
    func bigFilesMissingRoots() async throws {
        let found = try await BigFilesScanner(minimumSize: 1).scan(environment())
        #expect(found.isEmpty)
    }

    // MARK: - Unused apps

    @discardableResult
    private func app(_ path: String, id: String, bytes: Int = 10) throws -> URL {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL"], format: .xml, options: 0)
        let info = try dir.file("Applications/\(path)/Contents/Info.plist")
        try plist.write(to: info)
        try dir.file("Applications/\(path)/Contents/MacOS/binary", bytes: bytes)
        return dir.url.appending(path: "Applications/\(path)")
    }

    @Test("Unused apps: an app last opened more than 6 months ago, with its size and date")
    func unusedOldApp() async throws {
        let url = try app("Old.app", id: "com.vendor.Old", bytes: 64)
        let opened = daysAgo(200)

        let scanner = UnusedAppsScanner()
        let found = try await scanner.scan(environment(opened: ["Old.app": opened]))

        #expect(scanner.kind == .unusedApps && scanner.kind.group == .yourCall)
        #expect(names(found) == ["Old.app"])
        #expect(found.first?.bytes == CleanWalker.size(of: url))
        #expect(found.first?.detail == "Last opened \(opened.formatted(date: .abbreviated, time: .omitted))")
    }

    @Test("Unused apps: an app opened within 6 months is kept")
    func unusedRecentApp() async throws {
        try app("Recent.app", id: "com.vendor.Recent")
        try app("Edge.app", id: "com.vendor.Edge")
        let found = try await UnusedAppsScanner().scan(
            environment(opened: ["Recent.app": daysAgo(10), "Edge.app": daysAgo(182)]))
        #expect(found.isEmpty)
    }

    @Test("Unused apps: an app whose last-opened date is unknown is never listed")
    func unusedUnknownDate() async throws {
        try app("Unknown.app", id: "com.vendor.Unknown")
        let found = try await UnusedAppsScanner().scan(environment())
        #expect(found.isEmpty)
    }

    @Test("Unused apps: Apple's apps are never listed")
    func unusedAppleApp() async throws {
        try app("Pages.app", id: "com.apple.iWork.Pages")
        let found = try await UnusedAppsScanner().scan(environment(opened: ["Pages.app": daysAgo(400)]))
        #expect(found.isEmpty)
    }

    @Test("Unused apps: this app is never listed")
    func unusedOwnApp() async throws {
        try app("Attic.app", id: "com.juancasanueva.attic")
        let found = try await UnusedAppsScanner().scan(environment(opened: ["Attic.app": daysAgo(400)]))
        #expect(found.isEmpty)
    }

    @Test("Unused apps: apps one sub-folder down are found, deeper ones and plain folders aren't")
    func unusedSubFolderApp() async throws {
        try app("Utilities/Tool.app", id: "com.vendor.Tool")
        try app("Suite/Deeper/Buried.app", id: "com.vendor.Buried")
        try dir.folder("Applications/NotAnApp")
        let old = daysAgo(300)

        let found = try await UnusedAppsScanner().scan(
            environment(opened: ["Tool.app": old, "Buried.app": old, "NotAnApp": old]))

        #expect(names(found) == ["Tool.app"])
    }

    // MARK: - Leftovers

    /// Creates an old leftover at ~/Library/<path>, a file or a folder with an old child.
    @discardableResult
    private func leftover(_ path: String, folder: Bool = true, daysAgo days: Double = 90) throws -> URL {
        let url: URL
        if folder {
            let child = try dir.file("Library/\(path)/data.bin", bytes: 5)
            try touch(child, daysAgo: days)
            url = child.deletingLastPathComponent()
        } else {
            url = try dir.file("Library/\(path)", bytes: 5)
        }
        try touch(url, daysAgo: days)
        return url
    }

    @Test("Leftovers: bundle-id entries of deleted apps in each of the six Library folders")
    func leftoversEverywhere() async throws {
        try leftover("Application Support/com.gone.Support")
        try leftover("Caches/com.gone.Cache")
        try leftover("Preferences/com.gone.Prefs.plist", folder: false)
        try leftover("Saved Application State/com.gone.State.savedState")
        try leftover("HTTPStorages/com.gone.Http")
        try leftover("WebKit/com.gone.Web")

        let scanner = LeftoversScanner()
        let found = try await scanner.scan(environment())

        #expect(scanner.kind == .leftovers && scanner.kind.group == .yourCall)
        #expect(names(found) == [
            "com.gone.Support", "com.gone.Cache", "com.gone.Prefs.plist", "com.gone.State.savedState",
            "com.gone.Http", "com.gone.Web",
        ])
        let detail = Dictionary(uniqueKeysWithValues: found.map { ($0.url.lastPathComponent, $0.detail) })
        #expect(detail["com.gone.Support"] == "Application Support of “com.gone.Support”, an app that isn't installed")
        #expect(detail["com.gone.Prefs.plist"] == "Preferences of “com.gone.Prefs”, an app that isn't installed")
        #expect(detail["com.gone.State.savedState"] == "Saved Application State of “com.gone.State”, an app that isn't installed")
        #expect(found.first { $0.url.lastPathComponent == "com.gone.Support" }?.bytes
            == CleanWalker.size(of: dir.url.appending(path: "Library/Application Support/com.gone.Support")))
    }

    @Test("Leftovers: an installed app's own id is kept, whatever its case")
    func leftoversInstalledID() async throws {
        try leftover("Caches/com.foo.App")
        try leftover("Caches/COM.FOO.APP2")
        let found = try await LeftoversScanner().scan(environment(installed: ["com.foo.App", "com.foo.app2"]))
        #expect(found.isEmpty)
    }

    @Test("Leftovers: a helper of an installed app (its id as a dotted prefix) is kept")
    func leftoversHelperID() async throws {
        try leftover("Application Support/com.foo.App.helper")
        try leftover("Caches/com.foo.AppX")   // same vendor: kept too (helpers are often named freely)
        try leftover("Caches/com.bar.App")    // another vendor with nothing installed: listed
        let found = try await LeftoversScanner().scan(environment(installed: ["com.foo.App"]))
        #expect(names(found) == ["com.bar.App"])
    }

    @Test("Leftovers: any id of an installed app's vendor is kept")
    func leftoversSameVendorProduct() async throws {
        try leftover("Caches/com.foo.Suite.Helper")
        try leftover("Caches/com.foo.Other")   // same vendor, other product: kept
        try leftover("Caches/org.gone.Editor")  // nothing of this vendor installed: listed
        let found = try await LeftoversScanner().scan(environment(installed: ["com.foo.Suite.Mac"]))
        #expect(names(found) == ["org.gone.Editor"])
    }

    @Test("Leftovers: Apple's ids are kept, whatever their case")
    func leftoversApple() async throws {
        try leftover("Caches/com.apple.Safari")
        try leftover("Preferences/Com.Apple.Finder.plist", folder: false)
        let found = try await LeftoversScanner().scan(environment())
        #expect(found.isEmpty)
    }

    @Test("Leftovers: an entry changed within 30 days, or holding a recent file, is kept")
    func leftoversRecent() async throws {
        try leftover("Caches/com.gone.Recent", daysAgo: 5)
        try leftover("Preferences/com.gone.Fresh.plist", folder: false, daysAgo: 29)
        let folder = try leftover("Application Support/com.gone.Busy")
        let fresh = try dir.file("Library/Application Support/com.gone.Busy/new.bin", bytes: 1)
        try touch(fresh, daysAgo: 2)
        try touch(folder, daysAgo: 90)

        let found = try await LeftoversScanner().scan(environment())

        #expect(found.isEmpty)
    }

    @Test("Leftovers: names that aren't bundle ids are kept (plain names, two parts, dotfiles, odd characters)")
    func leftoversNotBundleIDs() async throws {
        try leftover("Application Support/Google")
        try leftover("Application Support/foo.bar")
        try leftover("Caches/.com.gone.Hidden")
        try leftover("Caches/com..gone")
        try leftover("Caches/com.gone.has space")
        try leftover("Caches/com.1gone.App")
        try leftover("WebKit/com.gone.")
        let found = try await LeftoversScanner().scan(environment())
        #expect(found.isEmpty)
    }

    @Test("Leftovers: Containers and Group Containers are left alone")
    func leftoversContainers() async throws {
        try leftover("Containers/com.gone.Sandboxed")
        try leftover("Group Containers/group.com.gone.Shared")
        let found = try await LeftoversScanner().scan(environment())
        #expect(found.isEmpty)
    }

    @Test("Leftovers: only .plist files count in Preferences")
    func leftoversPreferencesOnlyPlist() async throws {
        try leftover("Preferences/com.gone.Lock.lockfile", folder: false)
        try leftover("Preferences/com.gone.Folder")
        let found = try await LeftoversScanner().scan(environment())
        #expect(found.isEmpty)
    }

    @Test("Leftovers: this app's own entries are kept")
    func leftoversOwnID() async throws {
        try leftover("Caches/com.juancasanueva.attic")
        try leftover("Preferences/com.juancasanueva.attic.plist", folder: false)
        let found = try await LeftoversScanner().scan(environment())
        #expect(found.isEmpty)
    }
}

@MainActor
@Suite("Leftovers never list OS, installed-app or shared-tool data")
struct LeftoversSafetyTests {
    let dir: TemporaryDirectory
    static let now = Date(timeIntervalSince1970: 1_793_804_400)

    init() throws {
        dir = try TemporaryDirectory()
    }

    private func date(daysAgo: Double) -> Date { Self.now.addingTimeInterval(-daysAgo * 86_400) }

    /// Creates `Library/<path>` (a folder with one file inside, or a .plist file), all dated
    /// `daysAgo`, and returns the names the scanner lists.
    private func listed(_ path: String, installed: [String], daysAgo: Double = 90) async throws -> [String] {
        let url = dir.url.appending(path: "Library/\(path)")
        let fileManager = FileManager.default
        if url.pathExtension == "plist" {
            try dir.file("Library/\(path)", bytes: 8)
        } else {
            let inner = try dir.file("Library/\(path)/data.bin", bytes: 8)
            try fileManager.setAttributes([.modificationDate: date(daysAgo: daysAgo)], ofItemAtPath: inner.path)
        }
        try fileManager.setAttributes([.modificationDate: date(daysAgo: daysAgo)], ofItemAtPath: url.path)
        let apps = installed.map {
            InstalledApp(url: dir.url.appending(path: "Applications/\($0).app"), name: $0, bundleID: $0)
        }
        let environment = CleanEnvironment.testing(home: dir.url, now: Self.now, installedApps: apps)
        return try await LeftoversScanner().scan(environment).map(\.url.lastPathComponent)
    }

    @Test("Apple's and the OS's own data is never a leftover", arguments: [
        "Preferences/group.com.apple.mail.plist", "Preferences/org.cups.PrintingPrefs.plist",
        "Caches/group.com.apple.notes", "Caches/systemgroup.com.apple.configurationprofiles",
    ])
    func appleData(path: String) async throws {
        #expect(try await listed(path, installed: []).isEmpty)
    }

    @Test("Data of an installed app's vendor (helpers, agents, updaters) is kept", arguments: [
        ("Preferences/com.google.Keystone.Agent.plist", "com.google.Chrome"),
        ("Caches/com.microsoft.autoupdate2", "com.microsoft.Word"),
        ("Application Support/com.docker.helper", "com.docker.docker"),
        ("Application Support/com.raycast.shared", "com.raycast.macos"),
    ])
    func sameVendor(path: String, installed: String) async throws {
        #expect(try await listed(path, installed: [installed]).isEmpty)
    }

    @Test("Shared tools and SDK components (not one app's) are kept", arguments: [
        "HTTPStorages/com.github.Electron", "Preferences/com.android.Emulator.plist", "Caches/org.swift.swiftpm",
        "Caches/com.crashlytics.data", "Caches/com.onevcat.Kingfisher.ImageCache.default",
        "Preferences/com.Breakpad.crash_report_sender.plist", "Preferences/com.install4j.installations.plist",
        "Caches/com.segment.storage.abc", "Caches/com.telemetrydeck.cache", "Preferences/com.yourcompany.installerbase.plist",
        "Caches/org.sparkle-project.Sparkle",
    ])
    func sharedComponents(path: String) async throws {
        #expect(try await listed(path, installed: ["com.spotify.client"]).isEmpty)
    }

    @Test("A file changed deep inside an entry means it's still in use")
    func deepChange() async throws {
        let entry = dir.url.appending(path: "Library/Application Support/com.vendor.product")
        let db = try dir.file("Library/Application Support/com.vendor.product/Data/db.sqlite", bytes: 8)
        let fileManager = FileManager.default
        try fileManager.setAttributes([.modificationDate: date(daysAgo: 1)], ofItemAtPath: db.path)
        try fileManager.setAttributes([.modificationDate: date(daysAgo: 90)], ofItemAtPath: entry.appending(path: "Data").path)
        try fileManager.setAttributes([.modificationDate: date(daysAgo: 90)], ofItemAtPath: entry.path)
        let environment = CleanEnvironment.testing(home: dir.url, now: Self.now)

        #expect(try await LeftoversScanner().scan(environment).isEmpty)
    }

    @Test("Data of a really deleted app is still listed")
    func realLeftover() async throws {
        #expect(try await listed("Application Support/com.operasoftware.Opera", installed: ["com.google.Chrome"])
            == ["com.operasoftware.Opera"])
    }

    @Test("Apps are found deeper, such as vendor folders in Application Support, without entering apps")
    func deeperAppDiscovery() throws {
        try dir.folder("Root/Vendor/Sub/Tool.app/Contents")
        try dir.folder("Root/Outer.app/Contents/Helpers/Inner.app")
        let apps = CleanEnvironment.findApps(in: [dir.url.appending(path: "Root")], maxDepth: 3)
        #expect(Set(apps.map(\.name)) == ["Tool", "Outer"])
    }
}
