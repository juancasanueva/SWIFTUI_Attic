import Foundation

/// What the file browser shows. Without criteria it lists the focused folder; with any
/// criterion it searches everything inside the chosen scope.
nonisolated struct FileBrowserQuery: Sendable, Equatable {
    enum Scope: Sendable, Hashable, CaseIterable {
        case currentContents, entireScan
    }

    enum KindFilter: Sendable, Hashable, CaseIterable {
        case folder, package, file

        func matches(_ kind: NodeKind) -> Bool {
            switch self {
            case .folder: kind == .folder
            case .package: kind == .package
            case .file: !kind.isContainer
            }
        }
    }

    enum SortField: Sendable, Hashable {
        case name, allocatedSize, kind, fileCount, modified
    }

    static let resultLimit = 20_000

    var scope = Scope.currentContents
    var text = ""
    var kinds: Set<KindFilter> = []
    var minimumSize: Int64 = 0
    var sortField = SortField.allocatedSize
    var ascending = false

    var hasCriteria: Bool {
        !trimmedText.isEmpty || !kinds.isEmpty || minimumSize > 0
    }

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    func results(in tree: FileTree, focus: NodeID) throws -> [NodeID] {
        try Task.checkCancellation()
        let matches = hasCriteria
            ? try search(tree, from: scope == .entireScan ? FileTree.rootID : focus)
            : Array(tree.children(of: focus))
        return Array(sorted(matches, in: tree).prefix(Self.resultLimit))
    }

    private func search(_ tree: FileTree, from start: NodeID) throws -> [NodeID] {
        let needle = trimmedText
        var matches: [NodeID] = []
        var stack = Array(tree.children(of: start))
        var visited = 0
        while let id = stack.popLast() {
            visited += 1
            if visited & 0xFFF == 0 { try Task.checkCancellation() }
            let node = tree[id]
            if node.allocatedSize >= minimumSize,
               kinds.isEmpty || kinds.contains(where: { $0.matches(node.kind) }),
               needle.isEmpty || node.name.localizedStandardContains(needle) {
                matches.append(id)
            }
            if node.childrenCount > 0 { stack.append(contentsOf: tree.children(of: id)) }
        }
        return matches
    }

    private func sorted(_ ids: [NodeID], in tree: FileTree) -> [NodeID] {
        ids.sorted { lhs, rhs in
            let (a, b) = (tree[lhs], tree[rhs])
            let order: ComparisonResult = switch sortField {
            case .name: a.name.localizedStandardCompare(b.name)
            case .allocatedSize: Self.compare(a.allocatedSize, b.allocatedSize)
            case .kind: Self.compare(a.kind.rawValue, b.kind.rawValue)
            case .fileCount: Self.compare(a.fileCount, b.fileCount)
            case .modified: Self.compare(a.modified, b.modified)
            }
            if order == .orderedSame {
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }
}
