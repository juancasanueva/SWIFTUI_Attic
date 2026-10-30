import SwiftUI

/// Colors shared by both charts. A branch keeps its hue at every depth.
nonisolated enum ChartPalette {
    private static let hues = [0.31, 0.52, 0.60, 0.44, 0.11, 0.76, 0.93, 0.17]

    static func sunburst(branch: Int, ring: Int, kind: NodeKind) -> Color {
        let hue = hues[abs(branch) % hues.count]
        if !kind.isContainer {
            return Color(hue: hue, saturation: 0.16, brightness: 0.46)
        }
        let depth = Double(min(ring, 7))
        return Color(hue: hue, saturation: 0.66 - depth * 0.04, brightness: 0.74 - depth * 0.055)
    }

    static func treemap(branch: Int, depth: Int, kind: NodeKind) -> Color {
        let hue = hues[abs(branch) % hues.count] + Double(depth % 3) * 0.035
        if !kind.isContainer {
            return Color(hue: hue, saturation: 0.32, brightness: 0.56)
        }
        return Color(hue: hue, saturation: 0.46, brightness: 0.64 - Double(min(depth, 5)) * 0.035)
    }
}

/// Shows a context menu for whatever is under the pointer. Being its own view keeps the
/// chart from being re-evaluated each time the hovered item changes.
private struct HoveredItemMenu: View {
    let model: WorkspaceModel

    var body: some View {
        if let id = model.hoveredID {
            NodeActionsMenu(model: model, ids: model.selection.contains(id) ? model.selection.sorted() : [id])
        }
    }
}

struct ChartAreaView: View {
    let model: WorkspaceModel
    let tree: FileTree

    var body: some View {
        Group {
            if !tree[model.focus].kind.isContainer || tree[model.focus].allocatedSize == 0 {
                ContentUnavailableView("Nothing to Show", systemImage: "chart.pie", description: Text("This folder has no allocated contents."))
            } else {
                switch model.chartMode {
                case .sunburst:
                    SunburstChartView(model: model, tree: tree)
                        .overlay(alignment: .topLeading) { ChartSummaryCard(model: model, tree: tree).padding(12) }
                case .treemap:
                    TreemapChartView(model: model, tree: tree)
                }
            }
        }
        .contextMenu { HoveredItemMenu(model: model) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ChartSummaryCard: View {
    let model: WorkspaceModel
    let tree: FileTree

    private var shownID: NodeID { model.hoveredID ?? model.selection.first ?? model.focus }

    var body: some View {
        let node = tree[shownID]
        let share = tree[model.focus].allocatedSize > 0
            ? Double(node.allocatedSize) / Double(tree[model.focus].allocatedSize) : 0
        VStack(alignment: .leading, spacing: 4) {
            Text(node.kind.isContainer ? "Folder" : "File").font(.caption).foregroundStyle(.secondary)
            Text(node.name).font(.headline).lineLimit(2)
            Text(node.allocatedSize.byteText).font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            Text("\(share.percentText) of current focus").font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 200, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .allowsHitTesting(false)
    }
}

/// Selects on a single click and drills in on a double click, without the delay that
/// stacked tap gestures would add to the single click.
struct ChartClicks: ViewModifier {
    let onClick: (CGPoint) -> Void
    let onDoubleClick: (CGPoint) -> Void

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(SpatialTapGesture(count: 1).onEnded { onClick($0.location) })
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { onDoubleClick($0.location) })
    }
}

struct ChartTooltip: View {
    let tree: FileTree
    let id: NodeID
    let focus: NodeID

    var body: some View {
        let node = tree[id]
        let share = tree[focus].allocatedSize > 0 ? Double(node.allocatedSize) / Double(tree[focus].allocatedSize) : 0
        VStack(alignment: .leading, spacing: 3) {
            Label(node.name, systemImage: node.kind.symbol).font(.callout.weight(.semibold)).lineLimit(1)
            Text("\(node.allocatedSize.byteText) · \(share.percentText) of \(tree[focus].name)")
                .font(.caption.weight(.medium))
            if node.kind.isContainer {
                Text("\(node.fileCount.formatted()) files").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: 280, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .allowsHitTesting(false)
    }
}
