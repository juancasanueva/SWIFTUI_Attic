import CoreGraphics
import Foundation

nonisolated struct TreemapCell: Sendable, Identifiable {
    let id: NodeID
    let rect: CGRect
    let depth: Int
    /// Index of the focus child this cell descends from. Drives the color.
    let branch: Int
    let kind: NodeKind
    let showsHeader: Bool
}

/// Nested squarified treemap of the focused folder. Cells are stored parents first, so
/// drawing them in order paints folders underneath their contents.
nonisolated struct TreemapLayout: Sendable {
    static let headerHeight: CGFloat = 18
    private static let nestingPadding: CGFloat = 2
    private static let minimumArea = 6.0
    private static let minimumNestedSide: CGFloat = 26
    private static let maximumCells = 40_000

    let focus: NodeID
    private(set) var cells: [TreemapCell] = []

    init(tree: FileTree, focus: NodeID, bounds: CGRect, gap: CGFloat = 1) {
        self.focus = focus
        place(children: focus, in: bounds, depth: 0, branch: nil, tree: tree, gap: gap)
    }

    /// The deepest cell under the point.
    func cell(at point: CGPoint) -> TreemapCell? {
        cells.last { $0.rect.contains(point) }
    }

    private mutating func place(children parent: NodeID, in area: CGRect, depth: Int, branch: Int?, tree: FileTree, gap: CGFloat) {
        let children = tree.children(of: parent)
        let total = children.reduce(Int64(0)) { $0 + tree[$1].allocatedSize }
        guard total > 0, area.width > 0, area.height > 0 else { return }

        let scale = Double(area.width * area.height) / Double(total)
        var items: [Squarifier.Item] = []
        var remainder = Double(area.width * area.height)
        for child in children {
            let itemArea = Double(tree[child].allocatedSize) * scale
            guard itemArea >= Self.minimumArea else { break }
            items.append(Squarifier.Item(id: child, area: itemArea))
            remainder -= itemArea
        }
        // What is too small to draw still takes its share, leaving the parent visible.
        if remainder > 1 { items.append(Squarifier.Item(id: nil, area: remainder)) }

        var index = 0
        for placed in Squarifier.layout(items, in: area) {
            guard let id = placed.id, cells.count < Self.maximumCells else { continue }
            let cellBranch = branch ?? index
            index += 1
            let rect = placed.rect.insetBy(dx: gap / 2, dy: gap / 2)
            guard rect.width > 0, rect.height > 0 else { continue }

            let node = tree[id]
            let nests = node.kind.isContainer && node.childrenCount > 0
                && rect.width >= Self.minimumNestedSide
                && rect.height >= Self.headerHeight + Self.minimumNestedSide / 2
            cells.append(TreemapCell(
                id: id, rect: rect, depth: depth, branch: cellBranch, kind: node.kind, showsHeader: nests))
            if nests {
                let content = CGRect(
                    x: rect.minX + Self.nestingPadding,
                    y: rect.minY + Self.headerHeight,
                    width: rect.width - Self.nestingPadding * 2,
                    height: rect.height - Self.headerHeight - Self.nestingPadding)
                place(children: id, in: content, depth: depth + 1, branch: cellBranch, tree: tree, gap: gap)
            }
        }
    }
}

/// Squarified treemap (Bruls, Huizing, van Wijk): items fill the shorter side of the
/// remaining space, one row at a time, while that keeps their aspect ratio improving.
private nonisolated enum Squarifier {
    struct Item {
        let id: NodeID?
        let area: Double
    }

    static func layout(_ items: [Item], in bounds: CGRect) -> [(id: NodeID?, rect: CGRect)] {
        var result: [(id: NodeID?, rect: CGRect)] = []
        result.reserveCapacity(items.count)
        var remaining = bounds
        var row: [Item] = []
        var rowArea = 0.0

        func worstRatio(_ area: Double, smallest: Double, largest: Double, side: Double) -> Double {
            let thickness = area / side
            return max(largest / (thickness * thickness), (thickness * thickness) / smallest)
        }

        for item in items {
            let side = Double(min(remaining.width, remaining.height))
            if !row.isEmpty {
                // Items arrive largest first, apart from the trailing remainder.
                let largest = row.map(\.area).max()!
                let smallest = row.map(\.area).min()!
                let current = worstRatio(rowArea, smallest: smallest, largest: largest, side: side)
                let extended = worstRatio(
                    rowArea + item.area, smallest: min(smallest, item.area), largest: max(largest, item.area), side: side)
                if extended > current {
                    flush(row, rowArea, into: &result, remaining: &remaining)
                    row.removeAll(keepingCapacity: true)
                    rowArea = 0
                }
            }
            row.append(item)
            rowArea += item.area
        }
        if !row.isEmpty { flush(row, rowArea, into: &result, remaining: &remaining) }
        return result
    }

    private static func flush(
        _ row: [Item], _ area: Double, into result: inout [(id: NodeID?, rect: CGRect)], remaining: inout CGRect
    ) {
        if remaining.width >= remaining.height {
            let width = CGFloat(area / Double(remaining.height))
            var y = remaining.minY
            for item in row {
                let height = CGFloat(item.area) / width
                result.append((item.id, CGRect(x: remaining.minX, y: y, width: width, height: height)))
                y += height
            }
            remaining = CGRect(x: remaining.minX + width, y: remaining.minY, width: max(remaining.width - width, 0), height: remaining.height)
        } else {
            let height = CGFloat(area / Double(remaining.width))
            var x = remaining.minX
            for item in row {
                let width = CGFloat(item.area) / height
                result.append((item.id, CGRect(x: x, y: remaining.minY, width: width, height: height)))
                x += width
            }
            remaining = CGRect(x: remaining.minX, y: remaining.minY + height, width: remaining.width, height: max(remaining.height - height, 0))
        }
    }
}
