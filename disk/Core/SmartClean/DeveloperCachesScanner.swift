import Foundation

/// Developer caches from a strict list, plus node_modules of projects untouched for 6 months.
nonisolated struct DeveloperCachesScanner: SuggestionScanner {
    let kind = SuggestionKind.developerCaches

    /// The only cache folders ever suggested, relative to the home folder. Nothing else is.
    static let caches: [(path: String, detail: String)] = [
        ("Library/Developer/Xcode/DerivedData", "Xcode build products, rebuilt on the next build"),
        ("Library/Developer/Xcode/iOS DeviceSupport", "Xcode iOS device support, downloaded again when a device connects"),
        ("Library/Developer/Xcode/watchOS DeviceSupport", "Xcode watchOS device support, downloaded again when a device connects"),
        ("Library/Developer/Xcode/tvOS DeviceSupport", "Xcode tvOS device support, downloaded again when a device connects"),
        ("Library/Developer/Xcode/visionOS DeviceSupport", "Xcode visionOS device support, downloaded again when a device connects"),
        ("Library/Developer/CoreSimulator/Caches", "Simulator caches, rebuilt when a simulator boots"),
        (".npm/_cacache", "npm download cache"),
        ("Library/Caches/Homebrew", "Homebrew download cache"),
        ("Library/Caches/pip", "pip download cache"),
        ("Library/Caches/Yarn", "Yarn package cache"),
        (".yarn/berry/cache", "Yarn package cache"),
        ("Library/Caches/CocoaPods", "CocoaPods download cache"),
    ]

    /// Folders searched for node_modules besides the user folders, relative to the home folder.
    static let projectFolders = ["Developer", "Projects", "src", "code"]

    /// "6 months" without a project change, in days.
    static let untouchedDays = 182

    func scan(_ environment: CleanEnvironment) async throws -> [CleanCandidate] {
        var candidates: [CleanCandidate] = []

        for cache in Self.caches {
            try Task.checkCancellation()
            let url = environment.home.appending(path: cache.path)
            guard Self.isRealFolder(url) else { continue }
            let bytes = CleanWalker.size(of: url)
            if bytes > 0 { candidates.append(CleanCandidate(url: url, bytes: bytes, detail: cache.detail)) }
        }

        let roots = (environment.userFolders + Self.projectFolders.map { environment.home.appending(path: $0) })
            .filter(Self.isRealFolder)
        let cutoff = environment.now.addingTimeInterval(-Double(Self.untouchedDays) * 86_400)
        for modules in CleanWalker.directories(named: "node_modules", in: roots, maxDepth: 5) {
            try Task.checkCancellation()
            guard let touched = Self.lastTouched(project: modules.deletingLastPathComponent()),
                  touched < cutoff else { continue }
            let since = touched.formatted(date: .abbreviated, time: .omitted)
            candidates.append(CleanCandidate(
                url: modules, bytes: CleanWalker.size(of: modules),
                detail: "Project untouched since \(since)", isTickedByDefault: false))
        }
        return candidates
    }

    /// A folder that is really there: not a link, not a file.
    private static func isRealFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    /// The newest change among the project's own items (node_modules aside), or the folder's
    /// date when it holds nothing else. `nil` when unreadable, so the project is left alone.
    private static func lastTouched(project: URL) -> Date? {
        let key = URLResourceKey.contentModificationDateKey
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: project, includingPropertiesForKeys: [key]) else { return nil }
        let others = children.filter { $0.lastPathComponent != "node_modules" }
        guard !others.isEmpty else { return try? project.resourceValues(forKeys: [key]).contentModificationDate }
        let dates = others.compactMap { try? $0.resourceValues(forKeys: [key]).contentModificationDate }
        // An item whose date can't be read might be recent: unknown is not "untouched".
        guard dates.count == others.count else { return nil }
        return dates.max()
    }
}
