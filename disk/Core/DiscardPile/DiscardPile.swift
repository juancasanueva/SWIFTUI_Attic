import Foundation

/// Refuses to trash locations whose loss would damage the system or the user's account.
nonisolated struct TrashSafetyPolicy: Sendable {
    private static let protectedPaths: Set<String> = [
        "/", "/System", "/Library", "/Applications", "/Users", "/Volumes", "/private", "/bin", "/sbin", "/usr",
        "/etc", "/var", "/tmp", "/opt", "/cores", "/dev",
    ]
    private static let protectedPrefixes = [
        "/System/", "/bin/", "/sbin/", "/usr/", "/etc/", "/var/db/", "/private/etc/", "/private/var/db/", "/dev/",
    ]
    private static let protectedHomeFolders = [
        "Library", "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Applications",
    ]

    let homePath: String

    init(homePath: String = NSHomeDirectory()) {
        self.homePath = homePath
    }

    /// Why the path must not be trashed, or nil when it may be.
    func refusal(forPath path: String) -> String? {
        if Self.protectedPaths.contains(path) { return "System location" }
        if path.hasPrefix("/usr/local/") { return nil }
        if Self.protectedPrefixes.contains(where: path.hasPrefix) { return "Part of macOS" }
        if path.hasPrefix("/Volumes/"), !path.dropFirst("/Volumes/".count).contains("/") { return "Volume root" }
        if path == homePath || homePath.hasPrefix(path + "/") { return "Contains your home folder" }
        if Self.protectedHomeFolders.contains(where: { path == homePath + "/" + $0 }) { return "Standard home folder" }
        return nil
    }
}

nonisolated struct TrashFailure: Sendable, Hashable {
    let path: String
    let reason: String
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

    /// The pile without anything already covered by a folder that is also in the pile.
    func effectiveItems(in tree: FileTree) -> [NodeID] {
        Self.outermost(items, in: tree)
    }

    func totalSize(in tree: FileTree) -> Int64 {
        effectiveItems(in: tree).reduce(0) { $0 + tree[$1].allocatedSize }
    }

    /// Moves what the policy allows and reports the rest. Anything refused or failed stays
    /// in the pile and in the tree, so what the user sees always matches the disk.
    func moveToTrash(in tree: FileTree, policy: TrashSafetyPolicy, move: (URL) throws -> Void) -> TrashOutcome {
        var failures: [TrashFailure] = []
        var allowed: [NodeID] = []
        for id in items where tree.contains(id) {
            if id == FileTree.rootID {
                failures.append(TrashFailure(path: tree.path(of: id), reason: "This is the scanned location"))
            } else if let reason = policy.refusal(forPath: tree.path(of: id)) {
                failures.append(TrashFailure(path: tree.path(of: id), reason: reason))
            } else {
                allowed.append(id)
            }
        }

        var moved: [NodeID] = []
        var movedBytes: Int64 = 0
        for id in Self.outermost(allowed, in: tree) {
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

    private static func outermost(_ ids: [NodeID], in tree: FileTree) -> [NodeID] {
        let set = Set(ids)
        return ids.filter { id in
            tree.contains(id) && !tree.ancestors(of: id).dropLast().contains(where: set.contains)
        }
    }
}
