import CoreGraphics
import Foundation
import Testing
@testable import DiskCore

@Suite struct SunburstLayoutTests {
    @Test func firstRingSpansAreProportionalToSize() throws {
        let tree = sampleTree()
        let layout = SunburstLayout(tree: tree, focus: FileTree.rootID)

        let ring = layout.segments.filter { $0.ring == 0 }
        #expect(ring.map { tree[$0.id].name } == ["a", "b.app", "c.bin"])
        let a = try #require(ring.first)
        #expect(abs(a.startAngle) < 1e-9)
        #expect(abs(a.endAngle - .pi * 2 * 0.6) < 1e-9)
        #expect(abs(try #require(ring.last).endAngle - .pi * 2) < 1e-9)
    }

    @Test func childrenStayInsideTheirParentSpan() throws {
        let tree = sampleTree()
        let layout = SunburstLayout(tree: tree, focus: FileTree.rootID)
        let a = try #require(layout.segments.first { $0.id == tree.id("a") })
        let x = try #require(layout.segments.first { $0.id == tree.id("a/x.bin") })
        #expect(x.ring == 1)
        #expect(x.startAngle == a.startAngle)
        #expect(abs(x.endAngle - (a.startAngle + (a.endAngle - a.startAngle) * 400 / 600)) < 1e-9)
        #expect(x.branch == a.branch)
    }

    @Test func hitTestFindsTheSegmentUnderThePolarPoint() {
        let tree = sampleTree()
        let layout = SunburstLayout(tree: tree, focus: FileTree.rootID)

        #expect(layout.segment(ring: 0, angle: 0.1)?.id == tree.id("a"))
        #expect(layout.segment(ring: 0, angle: .pi * 2 * 0.95)?.id == tree.id("c.bin"))
        #expect(layout.segment(ring: 1, angle: .pi * 2 * 0.95) == nil, "c.bin has no children")
        #expect(layout.segment(ring: 9, angle: 0.1) == nil)
    }

    @Test func geometryConvertsPointsToRingsAndClockwiseAngles() throws {
        let geometry = SunburstGeometry(size: CGSize(width: 200, height: 200), ringCount: 4)
        let (centerX, centerY) = (100.0, 100.0)

        #expect(geometry.polar(at: CGPoint(x: centerX, y: centerY)) == nil, "the hole is empty")
        #expect(geometry.polar(at: CGPoint(x: 0, y: 0)) == nil, "outside the outer radius")

        let top = try #require(geometry.polar(at: CGPoint(x: centerX, y: centerY - geometry.holeRadius - 1)))
        #expect(top.ring == 0)
        #expect(abs(top.angle) < 1e-9)

        let right = try #require(geometry.polar(at: CGPoint(x: centerX + geometry.outerRadius - 1, y: centerY)))
        #expect(right.ring == 3)
        #expect(abs(right.angle - .pi / 2) < 1e-9)
    }

    @Test func slicesTooThinToSeeAreDropped() {
        let root = RawDirectory(name: "root")
        root.entries = [
            .init(name: "huge", kind: .file, allocatedSize: 10_000_000, logicalSize: 0, modified: 0),
            .init(name: "tiny", kind: .file, allocatedSize: 1, logicalSize: 0, modified: 0),
        ]
        let tree = FileTree(rootPath: "/r", rootDirectory: root)

        let layout = SunburstLayout(tree: tree, focus: FileTree.rootID)

        #expect(layout.segments.map { tree[$0.id].name } == ["huge"])
    }

    @Test func depthIsLimited() {
        var directory = RawDirectory(name: "leaf")
        directory.entries = [.init(name: "f", kind: .file, allocatedSize: 10, logicalSize: 0, modified: 0)]
        for index in 0..<20 {
            let parent = RawDirectory(name: "d\(index)")
            parent.subdirectories = [directory]
            directory = parent
        }
        let tree = FileTree(rootPath: "/r", rootDirectory: directory)

        let layout = SunburstLayout(tree: tree, focus: FileTree.rootID, maxRings: 5)

        #expect(layout.ringCount == 5)
    }
}

@Suite struct TreemapLayoutTests {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 500)

    @Test func topLevelAreasAreProportionalToSize() throws {
        let tree = sampleTree()
        let layout = TreemapLayout(tree: tree, focus: FileTree.rootID, bounds: bounds, gap: 0)

        let top = layout.cells.filter { $0.depth == 0 }
        let area = { (cell: TreemapCell) in cell.rect.width * cell.rect.height }
        let a = try #require(top.first { $0.id == tree.id("a") })
        let c = try #require(top.first { $0.id == tree.id("c.bin") })
        #expect(abs(area(a) - bounds.width * bounds.height * 0.6) < 1)
        #expect(abs(area(c) - bounds.width * bounds.height * 0.1) < 1)
    }

    @Test func cellsStayInsideBoundsAndSiblingsDoNotOverlap() {
        let tree = sampleTree()
        let layout = TreemapLayout(tree: tree, focus: FileTree.rootID, bounds: bounds)

        let top = layout.cells.filter { $0.depth == 0 }
        #expect(top.count == 3)
        for cell in layout.cells { #expect(bounds.insetBy(dx: -0.001, dy: -0.001).contains(cell.rect)) }
        for (index, cell) in top.enumerated() {
            for other in top[(index + 1)...] {
                #expect(cell.rect.intersection(other.rect).isEmpty || cell.rect.intersection(other.rect).width * cell.rect.intersection(other.rect).height < 0.01)
            }
        }
    }

    @Test func folderContentsNestBelowTheHeader() throws {
        let tree = sampleTree()
        let layout = TreemapLayout(tree: tree, focus: FileTree.rootID, bounds: bounds)

        let a = try #require(layout.cells.first { $0.id == tree.id("a") })
        let x = try #require(layout.cells.first { $0.id == tree.id("a/x.bin") })
        #expect(a.showsHeader)
        #expect(!x.showsHeader)
        #expect(x.depth == 1)
        #expect(x.rect.minY >= a.rect.minY + TreemapLayout.headerHeight)
        #expect(a.rect.contains(x.rect))
    }

    @Test func hitTestReturnsTheDeepestCell() {
        let tree = sampleTree()
        let layout = TreemapLayout(tree: tree, focus: FileTree.rootID, bounds: bounds)
        let x = layout.cells.first { $0.id == tree.id("a/x.bin") }!
        let a = layout.cells.first { $0.id == tree.id("a") }!

        #expect(layout.cell(at: CGPoint(x: x.rect.midX, y: x.rect.midY))?.id == x.id)
        #expect(layout.cell(at: CGPoint(x: a.rect.midX, y: a.rect.minY + 2))?.id == a.id, "the header belongs to the folder")
        #expect(layout.cell(at: CGPoint(x: -5, y: -5)) == nil)
    }

    @Test func rectanglesKeepAReasonableAspectRatio() {
        let root = RawDirectory(name: "root")
        root.entries = (0..<30).map { .init(name: "f\($0)", kind: .file, allocatedSize: 1000, logicalSize: 0, modified: 0) }
        let tree = FileTree(rootPath: "/r", rootDirectory: root)

        let layout = TreemapLayout(tree: tree, focus: FileTree.rootID, bounds: bounds)

        #expect(layout.cells.count == 30)
        for cell in layout.cells {
            #expect(max(cell.rect.width / cell.rect.height, cell.rect.height / cell.rect.width) < 3)
        }
    }

    @Test func itemsTooSmallToDrawAreOmitted() {
        let root = RawDirectory(name: "root")
        root.entries = [
            .init(name: "huge", kind: .file, allocatedSize: 100_000_000, logicalSize: 0, modified: 0),
            .init(name: "tiny", kind: .file, allocatedSize: 1, logicalSize: 0, modified: 0),
        ]
        let tree = FileTree(rootPath: "/r", rootDirectory: root)

        let layout = TreemapLayout(tree: tree, focus: FileTree.rootID, bounds: bounds)

        #expect(layout.cells.map { tree[$0.id].name } == ["huge"])
    }

    @Test func emptyFolderProducesNoCells() {
        let tree = FileTree(rootPath: "/r", rootDirectory: RawDirectory(name: "root"))
        #expect(TreemapLayout(tree: tree, focus: FileTree.rootID, bounds: bounds).cells.isEmpty)
    }
}
