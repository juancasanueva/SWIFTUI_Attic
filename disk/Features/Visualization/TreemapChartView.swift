import SwiftUI

struct TreemapChartView: View {
    let model: WorkspaceModel
    let tree: FileTree

    @State private var layout: TreemapLayout?

    private struct LayoutKey: Hashable {
        let focus: NodeID
        let revision: Int
        let size: CGSize
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let layout {
                    TreemapCanvas(layout: layout, tree: tree)
                    TreemapHighlight(model: model, layout: layout)
                    TreemapTooltipLayer(model: model, tree: tree, size: proxy.size)
                }
            }
            .contentShape(.rect)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    model.hoveredID = layout?.cell(at: location)?.id
                    model.hoverLocation = location
                case .ended:
                    model.hoveredID = nil
                }
            }
            .modifier(ChartClicks(
                onClick: { point in
                    if let id = layout?.cell(at: point)?.id {
                        model.selection = [id]
                    } else {
                        model.selection = []
                    }
                },
                onDoubleClick: { point in
                    if let id = layout?.cell(at: point)?.id { model.activate(id) }
                }))
            .task(id: LayoutKey(focus: model.focus, revision: model.revision, size: proxy.size)) {
                // A resize fires this repeatedly, so wait for the size to settle first.
                if layout != nil { try? await Task.sleep(for: .milliseconds(60)) }
                guard !Task.isCancelled else { return }
                let computed = await Self.makeLayout(tree: tree, focus: model.focus, size: proxy.size)
                if !Task.isCancelled { layout = computed }
            }
        }
        .padding(12)
        .accessibilityElement()
        .accessibilityLabel("Treemap of \(tree[model.focus].name)")
    }

    @concurrent
    private nonisolated static func makeLayout(tree: FileTree, focus: NodeID, size: CGSize) async -> TreemapLayout {
        TreemapLayout(tree: tree, focus: focus, bounds: CGRect(origin: .zero, size: size))
    }
}

private struct TreemapCanvas: View {
    let layout: TreemapLayout
    let tree: FileTree

    private static let maximumLabels = 1_200

    var body: some View {
        Canvas { context, _ in
            for cell in layout.cells {
                let shape = Path(roundedRect: cell.rect, cornerRadius: 2)
                context.fill(shape, with: .color(ChartPalette.treemap(branch: cell.branch, depth: cell.depth, kind: cell.kind)))
                context.stroke(shape, with: .color(.black.opacity(0.25)), lineWidth: 0.5)
            }
            var labels = 0
            for cell in layout.cells where labels < Self.maximumLabels && cell.rect.width >= 34 {
                let node = tree[cell.id]
                let title = Text(node.name).font(.caption.weight(.semibold)).foregroundStyle(.white)
                if cell.showsHeader {
                    let header = CGRect(x: cell.rect.minX + 5, y: cell.rect.minY + 1, width: cell.rect.width - 8, height: TreemapLayout.headerHeight - 2)
                    context.draw(context.resolve(title), in: header)
                    labels += 1
                } else if cell.rect.height >= 18 {
                    let inner = cell.rect.insetBy(dx: 5, dy: 3)
                    context.draw(context.resolve(title), in: CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: 15))
                    if cell.rect.height >= 36 {
                        let size = Text(node.allocatedSize.byteText).font(.caption2).foregroundStyle(.white.opacity(0.8))
                        context.draw(context.resolve(size), in: CGRect(x: inner.minX, y: inner.minY + 15, width: inner.width, height: 14))
                    }
                    labels += 1
                }
            }
        }
    }
}

private struct TreemapHighlight: View {
    let model: WorkspaceModel
    let layout: TreemapLayout

    var body: some View {
        let hovered = model.hoveredID
        let selection = model.selection
        let pile = model.discardPile
        Canvas { context, _ in
            for cell in layout.cells {
                let isHovered = cell.id == hovered
                let isSelected = selection.contains(cell.id)
                let isDiscarded = pile.contains(cell.id)
                guard isHovered || isSelected || isDiscarded else { continue }
                let shape = Path(roundedRect: cell.rect, cornerRadius: 2)
                if isDiscarded { context.fill(shape, with: .color(.red.opacity(0.45))) }
                if isHovered && !cell.showsHeader { context.fill(shape, with: .color(.white.opacity(0.18))) }
                if isSelected {
                    context.stroke(shape, with: .color(.accentColor), lineWidth: 2.5)
                } else if isHovered {
                    context.stroke(shape, with: .color(.white), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct TreemapTooltipLayer: View {
    let model: WorkspaceModel
    let tree: FileTree
    let size: CGSize

    var body: some View {
        if let id = model.hoveredID, tree.contains(id) {
            let location = model.hoverLocation
            ChartTooltip(tree: tree, id: id, focus: model.focus)
                .fixedSize()
                .alignmentGuide(.leading) { dimensions in
                    let x = location.x + 14
                    return -(x + dimensions.width > size.width ? location.x - dimensions.width - 14 : x)
                }
                .alignmentGuide(.top) { dimensions in
                    let y = location.y + 14
                    return -(y + dimensions.height > size.height ? location.y - dimensions.height - 14 : y)
                }
        }
    }
}
