import Foundation

typealias NodeID = Int32

nonisolated enum NodeKind: UInt8, Sendable, Hashable {
    case folder, package, file, symlink, other

    var isContainer: Bool { self == .folder || self == .package }
}

nonisolated struct FileNode: Sendable {
    var name: String
    var parent: NodeID
    var kind: NodeKind
    var isUnreadable: Bool
    var isRemoved = false
    var allocatedSize: Int64
    var logicalSize: Int64
    var modified: TimeInterval
    /// Files below this node. A file counts itself.
    var fileCount: Int32
    /// Folders below this node, not counting itself.
    var folderCount: Int32
    /// Unreadable folders at or below this node.
    var warningCount: Int32
    var childrenStart: Int32 = 0
    var childrenCount: Int32 = 0

    var modifiedDate: Date? { modified > 0 ? Date(timeIntervalSince1970: modified) : nil }
}

nonisolated struct ScanWarning: Sendable, Hashable {
    var path: String
    var message: String
}

/// Immutable result of a scan: a flat node array so millions of entries stay compact and
/// the tree can cross actors for free. Node IDs stay valid across `removing(_:)`.
nonisolated struct FileTree: Sendable {
    static let rootID: NodeID = 0

    let rootPath: String
    let scannedAt: Date
    private(set) var warnings: [ScanWarning]
    private var nodes: [FileNode]
    /// Children of each node, largest first, addressed by `childrenStart`/`childrenCount`.
    private var childIDs: [NodeID]

    subscript(id: NodeID) -> FileNode { nodes[Int(id)] }

    var root: FileNode { nodes[0] }

    func children(of id: NodeID) -> ArraySlice<NodeID> {
        let node = nodes[Int(id)]
        let start = Int(node.childrenStart)
        return childIDs[start..<(start + Int(node.childrenCount))]
    }

    /// Root first, `id` last.
    func ancestors(of id: NodeID) -> [NodeID] {
        var chain = [id]
        var current = id
        while current != Self.rootID {
            current = nodes[Int(current)].parent
            chain.append(current)
        }
        return chain.reversed()
    }

    func path(of id: NodeID) -> String {
        guard id != Self.rootID else { return rootPath }
        let names = ancestors(of: id).dropFirst().map { nodes[Int($0)].name }
        let joined = names.joined(separator: "/")
        return rootPath == "/" ? "/" + joined : rootPath + "/" + joined
    }

    func url(of id: NodeID) -> URL {
        URL(fileURLWithPath: path(of: id), isDirectory: nodes[Int(id)].kind.isContainer)
    }

    /// The node at an absolute path, used to carry state over to a fresh scan.
    func node(atPath path: String) -> NodeID? {
        guard path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/") else { return nil }
        var current = Self.rootID
        for part in path.dropFirst(rootPath.count).split(separator: "/") {
            guard let next = children(of: current).first(where: { nodes[Int($0)].name == part }) else { return nil }
            current = next
        }
        return current
    }

    /// False once the node, or a folder above it, has been removed.
    func contains(_ id: NodeID) -> Bool {
        guard id >= 0, Int(id) < nodes.count else { return false }
        return !ancestors(of: id).contains { nodes[Int($0)].isRemoved }
    }

    func isDescendant(_ id: NodeID, of ancestor: NodeID) -> Bool {
        var current = id
        while current != Self.rootID {
            current = nodes[Int(current)].parent
            if current == ancestor { return true }
        }
        return false
    }

    /// A copy without the given nodes, with every size above them updated.
    func removing(_ ids: some Sequence<NodeID>) -> FileTree {
        var copy = self
        for id in ids where id != Self.rootID && copy.contains(id) {
            copy.remove(id)
        }
        return copy
    }

    private mutating func remove(_ id: NodeID) {
        let removedPath = path(of: id)
        let node = nodes[Int(id)]
        let folders = node.folderCount + (node.kind.isContainer ? 1 : 0)
        let lineage = ancestors(of: id).dropLast()

        for ancestor in lineage {
            nodes[Int(ancestor)].allocatedSize -= node.allocatedSize
            nodes[Int(ancestor)].logicalSize -= node.logicalSize
            nodes[Int(ancestor)].fileCount -= node.fileCount
            nodes[Int(ancestor)].folderCount -= folders
            nodes[Int(ancestor)].warningCount -= node.warningCount
        }

        let parent = Int(node.parent)
        let start = Int(nodes[parent].childrenStart)
        let end = start + Int(nodes[parent].childrenCount)
        if let index = childIDs[start..<end].firstIndex(of: id) {
            childIDs[index..<(end - 1)] = childIDs[(index + 1)..<end]
            nodes[parent].childrenCount -= 1
        }
        nodes[Int(id)].isRemoved = true
        warnings.removeAll { $0.path == removedPath || $0.path.hasPrefix(removedPath + "/") }

        // Ancestors shrank, so their position among their siblings may have changed.
        for ancestor in lineage { sortChildren(of: ancestor) }
    }

    private mutating func sortChildren(of id: NodeID) {
        let start = Int(nodes[Int(id)].childrenStart)
        let end = start + Int(nodes[Int(id)].childrenCount)
        let nodes = self.nodes
        childIDs[start..<end].sort {
            let (a, b) = (nodes[Int($0)], nodes[Int($1)])
            return a.allocatedSize != b.allocatedSize ? a.allocatedSize > b.allocatedSize : a.name < b.name
        }
    }
}

// MARK: - Building

/// Mutable directory record filled in by one scanner worker at a time.
nonisolated final class RawDirectory: @unchecked Sendable {
    struct Entry {
        var name: String
        var kind: NodeKind
        var allocatedSize: Int64
        var logicalSize: Int64
        var modified: TimeInterval
    }

    let name: String
    let kind: NodeKind
    var modified: TimeInterval
    var isUnreadable = false
    var entries: [Entry] = []
    var subdirectories: [RawDirectory] = []

    init(name: String, kind: NodeKind = .folder, modified: TimeInterval = 0) {
        self.name = name
        self.kind = kind
        self.modified = modified
    }
}

extension FileTree {
    nonisolated init(rootPath: String, rootDirectory: RawDirectory, warnings: [ScanWarning] = [], scannedAt: Date = .now) {
        self.rootPath = rootPath
        self.scannedAt = scannedAt
        self.warnings = warnings.sorted { $0.path < $1.path }

        func folderNode(_ raw: RawDirectory, parent: NodeID) -> FileNode {
            FileNode(
                name: raw.name, parent: parent, kind: raw.kind, isUnreadable: raw.isUnreadable,
                allocatedSize: 0, logicalSize: 0, modified: raw.modified,
                fileCount: 0, folderCount: 0, warningCount: raw.isUnreadable ? 1 : 0)
        }

        // Breadth first: every parent gets a lower index than its children, which lets
        // the totals be rolled up with one reverse pass and no recursion.
        var nodes = [folderNode(rootDirectory, parent: -1)]
        var childIDs: [NodeID] = []
        var queue: [(raw: RawDirectory, id: NodeID)] = [(rootDirectory, 0)]
        var cursor = 0
        while cursor < queue.count {
            let (raw, id) = queue[cursor]
            queue[cursor].raw = rootDirectory
            cursor += 1
            nodes[Int(id)].childrenStart = Int32(childIDs.count)
            nodes[Int(id)].childrenCount = Int32(raw.entries.count + raw.subdirectories.count)
            for entry in raw.entries {
                childIDs.append(Int32(nodes.count))
                nodes.append(FileNode(
                    name: entry.name, parent: id, kind: entry.kind, isUnreadable: false,
                    allocatedSize: entry.allocatedSize, logicalSize: entry.logicalSize, modified: entry.modified,
                    fileCount: 1, folderCount: 0, warningCount: 0))
            }
            for directory in raw.subdirectories {
                let childID = Int32(nodes.count)
                childIDs.append(childID)
                nodes.append(folderNode(directory, parent: id))
                queue.append((directory, childID))
            }
        }

        for index in stride(from: nodes.count - 1, to: 0, by: -1) {
            let node = nodes[index]
            let parent = Int(node.parent)
            nodes[parent].allocatedSize += node.allocatedSize
            nodes[parent].logicalSize += node.logicalSize
            nodes[parent].fileCount += node.fileCount
            nodes[parent].folderCount += node.folderCount + (node.kind.isContainer ? 1 : 0)
            nodes[parent].warningCount += node.warningCount
        }

        self.nodes = nodes
        self.childIDs = childIDs
        for index in nodes.indices where nodes[index].childrenCount > 1 {
            sortChildren(of: Int32(index))
        }
    }
}
