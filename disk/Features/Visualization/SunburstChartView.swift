import SwiftUI

struct SunburstChartView: View {
    let model: WorkspaceModel
    let tree: FileTree

    @State private var layout: SunburstLayout?

    private var layoutKey: [Int] { [Int(model.focus), model.revision] }

    var body: some View {
        GeometryReader { proxy in
            let rings = max(layout?.ringCount ?? 1, 4)
            let geometry = SunburstGeometry(size: proxy.size, ringCount: rings)
            ZStack {
                if let layout {
                    SunburstCanvas(layout: layout, geometry: geometry)
                    SunburstHighlight(model: model, layout: layout, geometry: geometry)
                }
            }
            .contentShape(.rect)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): model.hoveredID = segment(at: location, geometry)?.id
                case .ended: model.hoveredID = nil
                }
            }
            .modifier(ChartClicks(
                onClick: { point in
                    if let id = segment(at: point, geometry)?.id {
                        model.selection = [id]
                    } else {
                        model.selection = []
                    }
                },
                onDoubleClick: { point in
                    if let id = segment(at: point, geometry)?.id {
                        model.activate(id)
                    } else if isInHole(point, geometry) {
                        model.goUp()
                    }
                }))
        }
        .padding(16)
        .task(id: layoutKey) {
            layout = await Self.makeLayout(tree: tree, focus: model.focus)
        }
        .accessibilityElement()
        .accessibilityLabel("Sunburst chart of \(tree[model.focus].name)")
    }

    private func segment(at point: CGPoint, _ geometry: SunburstGeometry) -> SunburstSegment? {
        guard let polar = geometry.polar(at: point) else { return nil }
        return layout?.segment(ring: polar.ring, angle: polar.angle)
    }

    private func isInHole(_ point: CGPoint, _ geometry: SunburstGeometry) -> Bool {
        hypot(point.x - geometry.center.x, point.y - geometry.center.y) < geometry.holeRadius
    }

    @concurrent
    private nonisolated static func makeLayout(tree: FileTree, focus: NodeID) async -> SunburstLayout {
        SunburstLayout(tree: tree, focus: focus)
    }
}

private extension SunburstGeometry {
    func path(for segment: SunburstSegment) -> Path {
        let inner = innerRadius(ofRing: segment.ring)
        let outer = inner + ringWidth
        let start = Angle(radians: segment.startAngle - .pi / 2)
        let end = Angle(radians: segment.endAngle - .pi / 2)
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}

private struct SunburstCanvas: View {
    @Environment(\.colorScheme) private var colorScheme

    let layout: SunburstLayout
    let geometry: SunburstGeometry

    var body: some View {
        Canvas { context, _ in
            let separator = colorScheme == .dark ? Color.black.opacity(0.55) : Color.white.opacity(0.75)
            for segment in layout.segments {
                let path = geometry.path(for: segment)
                context.fill(path, with: .color(ChartPalette.sunburst(branch: segment.branch, ring: segment.ring, kind: segment.kind)))
                context.stroke(path, with: .color(separator), lineWidth: 0.5)
            }
        }
    }
}

/// Redraws on hover and selection changes without touching the base canvas.
private struct SunburstHighlight: View {
    let model: WorkspaceModel
    let layout: SunburstLayout
    let geometry: SunburstGeometry

    var body: some View {
        let hovered = model.hoveredID
        let selection = model.selection
        let pile = model.discardPile
        Canvas { context, _ in
            for segment in layout.segments {
                let isHovered = segment.id == hovered
                let isSelected = selection.contains(segment.id)
                let isDiscarded = pile.contains(segment.id)
                guard isHovered || isSelected || isDiscarded else { continue }
                let path = geometry.path(for: segment)
                if isDiscarded {
                    context.fill(path, with: .color(.red.opacity(0.45)))
                }
                if isHovered {
                    context.fill(path, with: .color(.white.opacity(0.22)))
                }
                if isHovered || isSelected {
                    context.stroke(path, with: .color(.white), lineWidth: isSelected ? 2 : 1)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
