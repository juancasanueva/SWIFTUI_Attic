import CoreGraphics
import Foundation

nonisolated struct SunburstSegment: Sendable, Identifiable {
    let id: NodeID
    let ring: Int
    /// Radians, clockwise from twelve o'clock.
    let startAngle: Double
    let endAngle: Double
    /// Index of the focus child this segment descends from. Drives the color.
    let branch: Int
    let kind: NodeKind
}

/// Concentric rings around the focused folder. Each child takes a slice of its parent's
/// span in proportion to its allocated size.
nonisolated struct SunburstLayout: Sendable {
    static let defaultMaxRings = 7
    private static let minimumAngle = 0.003

    let focus: NodeID
    let segments: [SunburstSegment]
    private let ringRanges: [Range<Int>]

    var ringCount: Int { ringRanges.count }

    init(tree: FileTree, focus: NodeID, maxRings: Int = defaultMaxRings) {
        struct Span {
            let id: NodeID
            let start: Double
            let end: Double
            let branch: Int
        }

        self.focus = focus
        var segments: [SunburstSegment] = []
        var ranges: [Range<Int>] = []
        var level = [Span(id: focus, start: 0, end: .pi * 2, branch: -1)]

        for ring in 0..<maxRings {
            let ringStart = segments.count
            var next: [Span] = []
            for span in level {
                let total = tree[span.id].allocatedSize
                guard total > 0 else { continue }
                let scale = (span.end - span.start) / Double(total)
                var angle = span.start
                for (index, child) in tree.children(of: span.id).enumerated() {
                    let sweep = Double(tree[child].allocatedSize) * scale
                    // Children are sorted, so everything after the first thin slice is thinner.
                    guard sweep >= Self.minimumAngle else { break }
                    let branch = ring == 0 ? index : span.branch
                    let kind = tree[child].kind
                    segments.append(SunburstSegment(
                        id: child, ring: ring, startAngle: angle, endAngle: angle + sweep, branch: branch, kind: kind))
                    if kind.isContainer {
                        next.append(Span(id: child, start: angle, end: angle + sweep, branch: branch))
                    }
                    angle += sweep
                }
            }
            guard segments.count > ringStart else { break }
            ranges.append(ringStart..<segments.count)
            level = next
        }
        self.segments = segments
        ringRanges = ranges
    }

    func segment(ring: Int, angle: Double) -> SunburstSegment? {
        guard ringRanges.indices.contains(ring) else { return nil }
        var low = ringRanges[ring].lowerBound
        var high = ringRanges[ring].upperBound
        while low < high {
            let middle = (low + high) / 2
            let candidate = segments[middle]
            if angle < candidate.startAngle {
                high = middle
            } else if angle >= candidate.endAngle {
                low = middle + 1
            } else {
                return candidate
            }
        }
        return nil
    }
}

nonisolated struct SunburstGeometry: Sendable, Equatable {
    let center: CGPoint
    let outerRadius: Double
    let holeRadius: Double
    let ringWidth: Double
    let ringCount: Int

    init(size: CGSize, ringCount: Int) {
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        outerRadius = max(min(size.width, size.height) / 2 - 4, 1)
        holeRadius = outerRadius * 0.24
        self.ringCount = max(ringCount, 1)
        ringWidth = (outerRadius - holeRadius) / Double(self.ringCount)
    }

    func polar(at point: CGPoint) -> (ring: Int, angle: Double)? {
        let dx = Double(point.x - center.x)
        let dy = Double(point.y - center.y)
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance >= holeRadius, distance < outerRadius else { return nil }
        let angle = atan2(dx, -dy)
        return (Int((distance - holeRadius) / ringWidth), angle < 0 ? angle + .pi * 2 : angle)
    }

    func innerRadius(ofRing ring: Int) -> Double { holeRadius + Double(ring) * ringWidth }
}
