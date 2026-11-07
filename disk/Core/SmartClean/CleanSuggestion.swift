import CoreServices
import Foundation

/// The two sections of Smart Clean.
nonisolated enum CleanGroup: Sendable {
    /// Ticked by default.
    case safe
    /// Unticked by default: only the user knows.
    case yourCall

    var title: String {
        switch self {
        case .safe: "Safe to clear"
        case .yourCall: "Your call"
        }
    }
}

/// The nine Smart Clean suggestions, in display order.
nonisolated enum SuggestionKind: String, CaseIterable, Sendable {
    case developerCaches, duplicates, installers, mailAttachments
    case bigFiles, unusedApps, screenRecordings, oldDownloads, leftovers

    var group: CleanGroup {
        switch self {
        case .developerCaches, .duplicates, .installers, .mailAttachments: .safe
        default: .yourCall
        }
    }

    var title: String {
        switch self {
        case .developerCaches: "Developer caches"
        case .duplicates: "Duplicates"
        case .installers: "Installers"
        case .mailAttachments: "Mail attachments"
        case .bigFiles: "Big files"
        case .unusedApps: "Unused apps"
        case .screenRecordings: "Old screen recordings"
        case .oldDownloads: "Old downloads"
        case .leftovers: "Leftovers of deleted apps"
        }
    }

    /// Why the suggestion is made, shown under its title.
    var why: String {
        switch self {
        case .developerCaches: "Xcode, the Simulator, npm and more rebuild these when they need them."
        case .duplicates: "Copies of files you have. The copy you opened last is kept."
        case .installers: "For apps you already have."
        case .mailAttachments: "Copies of ones you opened. The originals stay in Mail."
        case .bigFiles: "Files of 1 GB or more. Only you know if you still need them."
        case .unusedApps: "Apps you haven't opened in 6 months."
        case .screenRecordings: "Screen recordings older than 30 days."
        case .oldDownloads: "Downloaded more than 90 days ago and not opened since."
        case .leftovers: "Settings and caches of apps that are no longer installed."
        }
    }

    var systemImage: String {
        switch self {
        case .developerCaches: "hammer"
        case .duplicates: "doc.on.doc"
        case .installers: "shippingbox"
        case .mailAttachments: "paperclip"
        case .bigFiles: "externaldrive"
        case .unusedApps: "app.dashed"
        case .screenRecordings: "record.circle"
        case .oldDownloads: "arrow.down.circle"
        case .leftovers: "trash.slash"
        }
    }
}

/// One item a suggestion would move to the Trash, and why.
nonisolated struct CleanCandidate: Identifiable, Hashable, Sendable {
    let url: URL
    let bytes: Int64
    /// Why this item, e.g. "Copy of ~/Documents/report.pdf".
    let detail: String
    /// `nil` follows the suggestion's group; `false` keeps it unticked (node_modules).
    let isTickedByDefault: Bool?
    /// For a duplicate: the copy of its set that is kept. Clean never trashes every copy.
    let keptCopy: URL?

    var id: URL { url }

    init(url: URL, bytes: Int64, detail: String, isTickedByDefault: Bool? = nil, keptCopy: URL? = nil) {
        self.url = url.canonical
        self.bytes = bytes
        self.detail = detail
        self.isTickedByDefault = isTickedByDefault
        self.keptCopy = keptCopy?.canonical
    }
}

/// A suggestion with what it found.
nonisolated struct CleanSuggestion: Identifiable, Equatable, Sendable {
    let kind: SuggestionKind
    var candidates: [CleanCandidate]
    var id: SuggestionKind { kind }
    var bytes: Int64 { candidates.reduce(0) { $0 + $1.bytes } }
}

/// An app found on the Mac.
nonisolated struct InstalledApp: Hashable, Sendable {
    let url: URL
    /// The bundle name without ".app".
    let name: String
    let bundleID: String?
}

/// Everything scanners know about the Mac, injectable so tests use a fake home.
nonisolated struct CleanEnvironment: Sendable {
    var home: URL
    /// Where user-installed apps live: /Applications and ~/Applications.
    var applicationFolders: [URL]
    var now: Date
    /// Every app found, Apple's included (for "is this app still installed?").
    var installedApps: [InstalledApp]
    var ownBundleID: String?
    /// When a file or app was last opened (Spotlight), `nil` when unknown.
    var lastOpened: @Sendable (URL) -> Date?
    /// Whether Spotlight marks the file as a screen capture.
    var isScreenCapture: @Sendable (URL) -> Bool

    var trash: URL { home.appending(path: ".Trash") }
    var library: URL { home.appending(path: "Library") }
    /// The folders scanned for duplicates and big files.
    var userFolders: [URL] {
        ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"].map { home.appending(path: $0) }
    }

    /// The real Mac. Reads app bundles, so call it off the main actor.
    static func live() -> CleanEnvironment {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let userApps = [URL(filePath: "/Applications"), home.appending(path: "Applications")]
        // Everywhere apps and their helpers live, so their data isn't taken for leftovers.
        let installed = findApps(in: userApps, maxDepth: 3)
            + findApps(in: [URL(filePath: "/System/Applications")], maxDepth: 1)
            + findApps(in: [URL(filePath: "/Library/Application Support"), home.appending(path: "Library/Application Support")], maxDepth: 4)
        return CleanEnvironment(
            home: home, applicationFolders: userApps, now: .now,
            installedApps: installed, ownBundleID: Bundle.main.bundleIdentifier,
            lastOpened: { spotlightValue($0, kMDItemLastUsedDate) as? Date },
            isScreenCapture: { (spotlightValue($0, "kMDItemIsScreenCapture" as CFString) as? Bool) == true })
    }

    /// .app bundles in `folders`, entering up to `maxDepth` levels of sub-folders (such as
    /// Utilities or a vendor folder) but never an app itself.
    static func findApps(in folders: [URL], maxDepth: Int = 1) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        func visit(_ folder: URL, depth: Int) {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
            let children = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
            for child in children {
                if child.pathExtension == "app" {
                    apps.append(InstalledApp(
                        url: child.canonical, name: child.deletingPathExtension().lastPathComponent,
                        bundleID: Bundle(url: child)?.bundleIdentifier))
                } else if depth < maxDepth, let values = try? child.resourceValues(forKeys: keys),
                          values.isDirectory == true, values.isSymbolicLink != true {
                    visit(child, depth: depth + 1)
                }
            }
        }
        folders.forEach { visit($0, depth: 0) }
        return apps
    }

    private static func spotlightValue(_ url: URL, _ attribute: CFString) -> Any? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, attribute)
    }
}

/// Finds one suggestion's candidates. Scanners only read; Smart Clean does the trashing.
nonisolated protocol SuggestionScanner: Sendable {
    var kind: SuggestionKind { get }
    /// Should check `Task.isCancelled` (or `try Task.checkCancellation()`) while walking.
    func scan(_ environment: CleanEnvironment) async throws -> [CleanCandidate]
}

/// File-system walking shared by the scanners.
nonisolated enum CleanWalker {
    /// Calls `visit` with every regular file of at least `minimumSize` bytes below `roots`.
    /// Never enters hidden items or packages (apps, Photos libraries…), never follows links,
    /// and skips iCloud files that aren't downloaded (reading them would download them).
    static func regularFiles(in roots: [URL], minimumSize: Int64, visit: (URL, Int64) throws -> Void) throws {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .ubiquitousItemDownloadingStatusKey]
        for root in roots {
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true })
            while let url = enumerator?.nextObject() as? URL {
                try Task.checkCancellation()
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                if !isDownloaded(values) { continue }
                let size = Int64(values.fileSize ?? 0)
                if size >= minimumSize { try visit(url.canonical, size) }
            }
        }
    }

    /// Whether a file's contents are on the Mac: not an iCloud file that is only in iCloud
    /// (reading it would download it).
    static func isDownloaded(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])).map(isDownloaded) ?? true
    }

    private static func isDownloaded(_ values: URLResourceValues) -> Bool {
        guard let status = values.ubiquitousItemDownloadingStatus else { return true }
        return status == .current
    }

    /// Folders named `name` below `roots`, at most `maxDepth` levels down (a root's children are
    /// level 1). Matches aren't entered; hidden folders, packages and links never are.
    static func directories(named name: String, in roots: [URL], maxDepth: Int) -> [URL] {
        var found: [URL] = []
        func visit(_ folder: URL, depth: Int) {
            guard !Task.isCancelled else { return }
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
            let children = ((try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                guard let values = try? child.resourceValues(forKeys: keys), values.isDirectory == true,
                      values.isSymbolicLink != true, values.isPackage != true else { continue }
                if child.lastPathComponent == name {
                    found.append(child.canonical)
                } else if depth < maxDepth {
                    visit(child, depth: depth + 1)
                }
            }
        }
        roots.forEach { visit($0, depth: 1) }
        return found
    }

    /// A file's size, or a folder's whole tree.
    static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true { return 0 }
        if values?.isDirectory == true { return (try? FolderSizeCalculator.measure(url).totalBytes) ?? 0 }
        return Int64(values?.fileSize ?? 0)
    }
}
