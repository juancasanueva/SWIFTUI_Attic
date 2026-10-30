import SwiftUI

struct DiscardPileSheet: View {
    @Environment(\.dismiss) private var dismiss

    let model: WorkspaceModel
    let tree: FileTree

    private var items: [NodeID] { model.discardPile.effectiveItems(in: tree) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Discard Pile").font(.title2.weight(.semibold))
                Text("\(items.count) \(items.count == 1 ? "item" : "items") · \(model.discardPile.totalSize(in: tree).byteText) to reclaim")
                    .foregroundStyle(.secondary)
            }
            List(items, id: \.self) { id in
                row(for: id)
            }
            .frame(minHeight: 280)
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView("No Items Marked", systemImage: "checklist")
                }
            }
            HStack {
                Button("Remove All", action: model.clearDiscardPile)
                    .disabled(items.isEmpty)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash…", role: .destructive) {
                    model.confirmMoveToTrash(model.discardPile.items)
                    dismiss()
                }
                .disabled(items.isEmpty)
            }
        }
        .padding()
        .frame(width: 620, height: 460)
    }

    private func row(for id: NodeID) -> some View {
        let refusal = TrashSafetyPolicy().refusal(forPath: tree.path(of: id))
            ?? (id == FileTree.rootID ? "This is the scanned location" : nil)
        return HStack(spacing: 10) {
            NodeIcon(kind: tree[id].kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(tree[id].name).lineLimit(1)
                Text(tree.path(of: id))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let refusal {
                    Label("Won't be moved: \(refusal)", systemImage: "exclamationmark.shield")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Text(tree[id].allocatedSize.byteText).monospacedDigit().foregroundStyle(.secondary)
            Button {
                model.removeFromDiscardPile(id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(tree[id].name) from Discard Pile")
        }
    }
}

struct TrashReportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let report: TrashReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Moved \(report.movedBytes.byteText) to the Trash").font(.title3.weight(.semibold))
            Text("These items weren't moved:").foregroundStyle(.secondary)
            List(report.failures, id: \.self) { failure in
                VStack(alignment: .leading) {
                    Text(failure.path).lineLimit(1).truncationMode(.middle)
                    Text(failure.reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 160)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 520)
    }
}
