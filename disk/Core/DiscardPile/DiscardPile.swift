import Foundation

/// Refuses to trash locations whose loss would damage the system or the user's account.
/// Paths are judged by where they really lead, so a symlink, a different capitalization or
/// a `/Volumes/<startup disk>` prefix cannot talk it into moving something protected.
nonisolated struct TrashSafetyPolicy: Sendable {
    private static let protectedPaths: Set<String> = [
        "/", "/system", "/library", "/applications", "/users", "/volumes", "/private", "/bin", "/sbin", "/usr",
        "/etc", "/var", "/tmp", "/opt", "/cores", "/dev", "/private/etc", "/private/var", "/private/tmp",
    ]
    private static let protectedPrefixes = [
        "/system/", "/bin/", "/sbin/", "/usr/", "/etc/", "/dev/", "/private/etc/", "/private/var/",
    ]
    private static let allowedPrefixes = ["/usr/local/", "/private/var/folders/"]
    private static let protectedHomeFolders = [
        "library", "desktop", "documents", "downloads", "movies", "music", "pictures", "public", "applications",
        ".ssh", ".gnupg", ".trash", "library/keychains",
    ]
    private static let dataVolumePrefix = "/system/volumes/data/"

    private let home: String

    init(homePath: String = NSHomeDirectory()) {
        home = Self.comparable(homePath)
    }

    /// Why the path must not be trashed, or nil when it may be.
    func refusal(forPath path: String) -> String? {
        // The path as written counts too: it is what the user is told will move.
        for candidate in [path.lowercased(), Self.comparable(path)] {
            if let reason = refusal(forComparable: candidate) { return reason }
        }
        return nil
    }

    private func refusal(forComparable path: String) -> String? {
        if Self.protectedPaths.contains(path) { return "System location" }
        if !Self.allowedPrefixes.contains(where: path.hasPrefix), Self.protectedPrefixes.contains(where: path.hasPrefix) {
            return "Part of macOS"
        }
        if path.hasPrefix("/volumes/"), !path.dropFirst("/volumes/".count).contains("/") { return "Volume root" }
        if path == home || home.hasPrefix(path + "/") { return "Contains your home folder" }
        if Self.protectedHomeFolders.contains(where: { path == home + "/" + $0 }) { return "Standard home folder" }
        return nil
    }

    private static func comparable(_ path: String) -> String {
        var result = canonical(path).lowercased()
        if result.hasPrefix(dataVolumePrefix) {
            result = "/" + result.dropFirst(dataVolumePrefix.count)
        }
        return result
    }

    /// The path the file system itself reports, with symlinks in the parent folders resolved
    /// and the real capitalization. A symlink stays itself, because trashing one moves only
    /// the link. Whatever cannot be opened is kept as written below its real parent.
    private static func canonical(_ path: String) -> String {
        guard path != "/", !path.isEmpty else { return "/" }
        var info = stat()
        if lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK, let reported = reportedPath(path) {
            return reported
        }
        return inResolvedParent(path)
    }

    private static func inResolvedParent(_ path: String) -> String {
        let nsPath = path as NSString
        let parent = resolvedFolder(nsPath.deletingLastPathComponent)
        return (parent == "/" ? "" : parent) + "/" + nsPath.lastPathComponent
    }

    /// A parent folder is always followed, unlike the item itself.
    private static func resolvedFolder(_ path: String) -> String {
        guard path != "/", !path.isEmpty else { return "/" }
        guard let resolved = realpath(path, nil) else { return inResolvedParent(path) }
        defer { free(resolved) }
        let target = String(cString: resolved)
        return reportedPath(target) ?? target
    }

    private static func reportedPath(_ path: String) -> String? {
        // O_EVTONLY opens without needing read permission on the item.
        let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
        return String(cString: buffer)
    }
}

nonisolated struct TrashFailure: Sendable, Hashable {
    let path: String
    let reason: String
}

/// What a move to the Trash would do. The review screen and the move itself both read this,
/// so what the user reviews is exactly what happens.
nonisolated struct TrashPlan: Sendable {
    struct Refusal: Sendable {
        let id: NodeID
        let reason: String
    }

    let moves: [NodeID]
    let refusals: [Refusal]
    /// Space the moves would reclaim. Refused items are not part of it.
    let bytes: Int64
}

nonisolated struct TrashOutcome: Sendable {
    let tree: FileTree
    let pile: DiscardPile
    let failures: [TrashFailure]
    let movedBytes: Int64
}

/// Items set aside for review. Nothing leaves the disk until `moveToTrash` runs.
nonisolated struct DiscardPile: Sendable, Equatable {
    private(set) var items: [NodeID] = []

    var isEmpty: Bool { items.isEmpty }

    func contains(_ id: NodeID) -> Bool { items.contains(id) }

    mutating func add(_ id: NodeID) {
        if !items.contains(id) { items.append(id) }
    }

    mutating func remove(_ id: NodeID) {
        items.removeAll { $0 == id }
    }

    mutating func removeAll() { items.removeAll() }

    /// Refused items never shelter what is inside them: an item inside a refused folder
    /// was marked on its own, and it is listed and moved on its own.
    func plan(in tree: FileTree, policy: TrashSafetyPolicy) -> TrashPlan {
        var refusals: [TrashPlan.Refusal] = []
        var allowed: [NodeID] = []
        for id in items where tree.contains(id) {
            if id == FileTree.rootID {
                refusals.append(.init(id: id, reason: "This is the scanned location"))
            } else if let reason = policy.refusal(forPath: tree.path(of: id)) {
                refusals.append(.init(id: id, reason: reason))
            } else {
                allowed.append(id)
            }
        }
        let allowedSet = Set(allowed)
        let moves = allowed.filter { !tree.ancestors(of: $0).dropLast().contains(where: allowedSet.contains) }
        return TrashPlan(moves: moves, refusals: refusals, bytes: moves.reduce(0) { $0 + tree[$1].allocatedSize })
    }

    /// Moves what the plan allows and reports the rest. Anything refused or failed stays
    /// in the pile and in the tree, so what the user sees always matches the disk.
    func moveToTrash(in tree: FileTree, policy: TrashSafetyPolicy, move: (URL) throws -> Void) -> TrashOutcome {
        let plan = plan(in: tree, policy: policy)
        var failures = plan.refusals.map { TrashFailure(path: tree.path(of: $0.id), reason: $0.reason) }

        var moved: [NodeID] = []
        var movedBytes: Int64 = 0
        for id in plan.moves {
            do {
                try move(tree.url(of: id))
                moved.append(id)
                movedBytes += tree[id].allocatedSize
            } catch {
                failures.append(TrashFailure(path: tree.path(of: id), reason: error.localizedDescription))
            }
        }

        let updatedTree = tree.removing(moved)
        var updatedPile = self
        updatedPile.items.removeAll { !updatedTree.contains($0) }
        return TrashOutcome(tree: updatedTree, pile: updatedPile, failures: failures, movedBytes: movedBytes)
    }
}
