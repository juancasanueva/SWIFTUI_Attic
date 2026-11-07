import AppKit
import Combine
import SwiftUI

/// The Smart Clean window: one model with its own file-operation queue, undone with the
/// window's ⌘Z.
struct SmartCleanWindow: View {
    static let id = "smart-clean"
    @Environment(\.undoManager) private var undoManager
    @State private var model = SmartCleanModel(actions: TrashActions())

    var body: some View {
        SmartCleanView(model: model, undoManager: undoManager)
            .onAppear { model.actions.undoManager = undoManager }
            .onChange(of: undoManager) { _, manager in model.actions.undoManager = manager }
            .task { await model.lookAgain() }
            .onDisappear { model.stopScanning() }
            .frame(minWidth: 560, minHeight: 520)
    }
}

/// How full the Mac is, then the nine suggestions in two sections, each saying why.
struct SmartCleanView: View {
    @Bindable var model: SmartCleanModel
    let undoManager: UndoManager?
    /// `UndoManager.canUndo` isn't observable, so it is copied here whenever the undo stack changes.
    @State private var canUndo = false

    var body: some View {
        VStack(spacing: 0) {
            StorageHeader(storage: model.storage, freeable: model.tickedBytes)
                .padding(16)
            Divider()
            List {
                ForEach([CleanGroup.safe, .yourCall], id: \.title) { group in
                    Section {
                        ForEach(model.suggestions(in: group)) { suggestion in
                            SuggestionRow(model: model, suggestion: suggestion)
                        }
                    } header: {
                        Text(group.title)
                    } footer: {
                        Text(group == .safe ? "Ticked for you." : "Starts unticked: only you know.")
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            footer.padding(12)
        }
        .alert("Empty the Trash?", isPresented: $model.isConfirmingEmptyTrash) {
            Button("Cancel", role: .cancel) { model.cancelEmptyTrash() }
            Button("Empty Trash", role: .destructive) {
                Task {
                    await model.confirmEmptyTrash()
                    // Dropping the steps that pointed into the Trash posts no notification.
                    refreshCanUndo()
                }
            }
        } message: {
            Text("Items in the Trash are deleted for good. This can't be undone.")
        }
        .alert(
            "Smart Clean couldn't finish.",
            isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } }),
            presenting: model.alertMessage
        ) { _ in
            Button("OK") { model.alertMessage = nil }
        } message: { Text($0) }
    }

    private var footer: some View {
        HStack {
            Button("Look Again") { Task { await model.lookAgain() } }
                .disabled(model.isScanning || model.isCleaning)
            Button("Undo") { undoManager?.undo() }
                .disabled(!canUndo)
            Button("Empty Trash…") { model.requestEmptyTrash() }
                // Off until the Trash is measured and holds something.
                .disabled((model.storage?.trash ?? 0) == 0 || model.isCleaning)
            Spacer()
            if model.isScanning || model.isCleaning { ProgressView().controlSize(.small) }
            Text("Everything goes to the Trash first.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(cleanTitle) { Task { await model.clean() } }
                .keyboardShortcut(.defaultAction)
                .disabled(model.itemsToClean.isEmpty || model.isCleaning || model.isScanning)
        }
        .onAppear(perform: refreshCanUndo)
        .onChange(of: undoManager) { refreshCanUndo() }
        .onReceive(undoChanges) { _ in refreshCanUndo() }
    }

    /// Posted when a step is registered, undone or redone.
    private var undoChanges: some Publisher<Notification, Never> {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange,
        ]
        return Publishers.MergeMany(names.map { center.publisher(for: $0) })
            .filter { [undoManager] in ($0.object as AnyObject?) === undoManager }
    }

    private func refreshCanUndo() {
        canUndo = undoManager?.canUndo ?? false
    }

    private var cleanTitle: String {
        let bytes = model.tickedBytes
        return bytes > 0 ? "Move \(bytes.byteText) to Trash" : "Move to Trash"
    }
}

/// "8.8 GB free of 245 GB", the used space by category, and what could be freed.
private struct StorageHeader: View {
    let storage: StorageOverview?
    let freeable: Int64

    private struct Segment: Identifiable {
        let title: String
        let bytes: Int64?
        let color: Color
        var id: String { title }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let storage {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(storage.available.byteText) free of \(storage.total.byteText)")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Text("\(volumeName) \(storage.used.byteText) used")
                        .foregroundStyle(.secondary)
                }
                bar(storage)
                legend(storage)
                Text(freeable > 0 ? "You could free about \(freeable.byteText)." : "Nothing ticked to free yet.")
                    .font(.callout)
                    .foregroundStyle(freeable > 0 ? Color.green : .secondary)
            } else {
                HStack { ProgressView().controlSize(.small); Text("Measuring storage…").foregroundStyle(.secondary) }
            }
        }
    }

    private var volumeName: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return (try? home.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "Disk"
    }

    private func segments(_ storage: StorageOverview) -> [Segment] {
        [
            Segment(title: "Apps", bytes: storage.apps, color: .blue),
            Segment(title: "Your files", bytes: storage.yourFiles, color: .orange),
            Segment(title: "System", bytes: storage.system, color: .gray),
            Segment(title: "Other", bytes: storage.other, color: .purple),
            Segment(title: "In the Trash", bytes: storage.trash, color: .red),
        ]
    }

    private func bar(_ storage: StorageOverview) -> some View {
        GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(segments(storage)) { segment in
                    if let bytes = segment.bytes, storage.total > 0 {
                        segment.color.frame(width: proxy.size.width * CGFloat(bytes) / CGFloat(storage.total))
                    }
                }
                Color.secondary.opacity(0.15)
            }
        }
        .frame(height: 14)
        .clipShape(.rect(cornerRadius: 4))
        .accessibilityElement()
        .accessibilityLabel("\(storage.used.byteText) used of \(storage.total.byteText)")
    }

    private func legend(_ storage: StorageOverview) -> some View {
        HStack(spacing: 14) {
            ForEach(segments(storage)) { segment in
                HStack(spacing: 4) {
                    Circle().fill(segment.color).frame(width: 8, height: 8)
                    Text(segment.title)
                    Text(segment.bytes.map { $0.byteText } ?? "…")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.caption)
            }
        }
    }
}

/// One suggestion: a tick for all its items, why it's made, its size, and its items.
private struct SuggestionRow: View {
    let model: SmartCleanModel
    let suggestion: CleanSuggestion
    @State private var isExpanded = false

    private var tickedCount: Int { suggestion.candidates.filter { model.isTicked($0.url) }.count }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(suggestion.candidates) { candidate in
                CandidateRow(model: model, candidate: candidate)
            }
        } label: {
            HStack(spacing: 10) {
                Toggle(isOn: Binding(
                    get: { !suggestion.candidates.isEmpty && tickedCount == suggestion.candidates.count },
                    set: { model.setAll(suggestion.kind, ticked: $0) }
                )) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .disabled(suggestion.candidates.isEmpty)
                Image(systemName: suggestion.kind.systemImage)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.kind.title).fontWeight(.medium)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.scanningKinds.contains(suggestion.kind) {
                    ProgressView().controlSize(.small)
                } else {
                    Text(suggestion.bytes.byteText)
                        .monospacedDigit()
                        .foregroundStyle(suggestion.candidates.isEmpty ? .secondary : .primary)
                }
            }
            .padding(.vertical, 2)
        }
        .disabled(suggestion.candidates.isEmpty && !model.scanningKinds.contains(suggestion.kind))
    }

    private var subtitle: String {
        if let failure = model.failures[suggestion.kind] { return "Couldn't look: \(failure)" }
        if model.scanningKinds.contains(suggestion.kind) { return "\(suggestion.kind.why) Looking…" }
        if suggestion.candidates.isEmpty { return "\(suggestion.kind.why) Nothing to clear." }
        let count = suggestion.candidates.count
        let items = count == 1 ? "1 item" : "\(count) items"
        let ticked = tickedCount == count ? "" : tickedCount == 0 ? ", none ticked" : ", \(tickedCount) ticked"
        return "\(suggestion.kind.why) \(items)\(ticked)."
    }
}

private struct CandidateRow: View {
    let model: SmartCleanModel
    let candidate: CleanCandidate

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { model.isTicked(candidate.url) }, set: { _ in model.toggle(candidate.url) })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            Image(nsImage: NSWorkspace.shared.icon(forFile: candidate.url.path))
                .resizable()
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(candidate.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(candidate.bytes.byteText).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            Button("Show", systemImage: "magnifyingglass") {
                NSWorkspace.shared.activateFileViewerSelecting([candidate.url])
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .help(candidate.url.path)
    }
}
