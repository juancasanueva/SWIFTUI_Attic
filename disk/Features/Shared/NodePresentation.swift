import SwiftUI

extension Int64 {
    var byteText: String { formatted(.byteCount(style: .file)) }
}

extension Double {
    var percentText: String { formatted(.percent.precision(.fractionLength(1))) }
}

extension Date {
    var shortText: String { formatted(date: .abbreviated, time: .shortened) }
}

extension NodeKind {
    var symbol: String {
        switch self {
        case .folder: "folder.fill"
        case .package: "shippingbox.fill"
        case .file: "doc.fill"
        case .symlink: "arrow.up.right.square"
        case .other: "questionmark.square"
        }
    }

    var tint: Color { self == .folder ? .blue : .secondary }
}

struct NodeIcon: View {
    let kind: NodeKind

    var body: some View {
        Image(systemName: kind.symbol)
            .foregroundStyle(kind.tint)
            .frame(width: 20)
    }
}

/// The actions available for any item, wherever it appears.
struct NodeActionsMenu: View {
    let model: WorkspaceModel
    let ids: [NodeID]

    private var inPile: Bool { ids.allSatisfy(model.discardPile.contains) }

    var body: some View {
        if let id = ids.first, let tree = model.tree {
            if ids.count == 1, tree[id].kind.isContainer {
                Button("Show Contents") { model.navigate(to: id) }
            }
            if ids.count == 1 {
                Button("Open") { model.open(id) }
                Button("Quick Look") { model.quickLook(id) }
            }
            Divider()
            Button("Reveal in Finder") { model.reveal(ids) }
            Button("Copy Path") { model.copyPaths(ids) }
            Divider()
            if inPile {
                Button("Remove from Discard Pile") { ids.forEach(model.removeFromDiscardPile) }
            } else {
                Button("Add to Discard Pile") { model.addToDiscardPile(ids) }
            }
            Button("Move to Trash…", role: .destructive) { model.confirmMoveToTrash(ids) }
        }
    }
}
