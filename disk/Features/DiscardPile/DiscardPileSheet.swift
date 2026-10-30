import SwiftUI

struct DiscardPileSheet: View {
    @Environment(\.dismiss) private var dismiss

    let model: WorkspaceModel
    let tree: FileTree

    @State private var isConfirming = false

    private var plan: TrashPlan { model.discardPile.plan(in: tree, policy: TrashSafetyPolicy()) }

    private var summary: String {
        let count = plan.moves.count
        return "\(count) \(count == 1 ? "item" : "items") · \(plan.bytes.byteText) to reclaim"
    }

    var body: some View {
        let plan = plan
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Discard Pile").font(.title2.weight(.semibold))
                Text(summary).foregroundStyle(.secondary)
            }
            List {
                ForEach(plan.moves, id: \.self) { id in
                    row(for: id, refusal: nil)
                }
                ForEach(plan.refusals, id: \.id) { refusal in
                    row(for: refusal.id, refusal: refusal.reason)
                }
            }
            .frame(minHeight: 280)
            .overlay {
                if plan.moves.isEmpty && plan.refusals.isEmpty {
                    ContentUnavailableView("No Items Marked", systemImage: "checklist")
                }
            }
            HStack {
                Button("Remove All", action: model.clearDiscardPile)
                    .disabled(model.discardPile.isEmpty)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash…", role: .destructive) { isConfirming = true }
                    .disabled(plan.moves.isEmpty)
            }
        }
        .padding()
        .frame(width: 620, height: 460)
        .confirmationDialog("Move \(summary)?", isPresented: $isConfirming) {
            Button("Move to Trash", role: .destructive) {
                model.confirmMoveToTrash(plan.moves)
                model.performPendingTrash()
                dismiss()
            }
        } message: {
            Text("You can restore these items from the Trash.")
        }
    }

    private func row(for id: NodeID, refusal: String?) -> some View {
        HStack(spacing: 10) {
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
