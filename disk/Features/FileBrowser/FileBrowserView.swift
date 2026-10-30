import QuickLook
import SwiftUI

struct FileBrowserView: View {
    @Bindable var model: WorkspaceModel

    @State private var sortOrder = [KeyPathComparator(\BrowserRow.allocatedSize, order: .reverse)]

    private var previewURLs: [URL] {
        guard let tree = model.tree else { return [] }
        return model.selection.sorted().map(tree.url(of:))
    }

    var body: some View {
        VStack(spacing: 0) {
            FileBrowserSearchBar(model: model)
            Divider()
            table
        }
        .task(id: model.browserKey) {
            await model.refreshBrowser()
        }
        .onChange(of: sortOrder) { apply(sortOrder) }
    }

    private var table: some View {
        Table(model.browserRows, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 8) {
                    NodeIcon(kind: row.kind)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.name).lineLimit(1)
                        if let subtitle = row.subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if model.discardPile.contains(row.id) {
                        Image(systemName: "trash.circle.fill")
                            .foregroundStyle(.red)
                            .accessibilityLabel("In Discard Pile")
                    }
                }
            }
            .width(min: 180, ideal: 320)
            TableColumn("Allocated", value: \.allocatedSize) { row in
                Text(row.allocatedSize.byteText).monospacedDigit()
            }
            .width(min: 80, ideal: 100)
            TableColumn("Kind", value: \.kindLabel) { row in
                Text(row.kindLabel).lineLimit(1)
            }
            .width(min: 70, ideal: 110)
            TableColumn("Files", value: \.fileCount) { row in
                Text(row.fileCount.formatted()).monospacedDigit()
            }
            .width(min: 50, ideal: 70)
            TableColumn("Modified", value: \.modified) { row in
                Text(row.modified > 0 ? Date(timeIntervalSince1970: row.modified).shortText : "—").lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        }
        .contextMenu(forSelectionType: NodeID.self) { ids in
            NodeActionsMenu(model: model, ids: ids.sorted())
        } primaryAction: { ids in
            if let id = ids.first { model.activate(id) }
        }
        .onKeyPress(.space) {
            guard let id = model.selection.first else { return .ignored }
            model.quickLook(id)
            return .handled
        }
        .quickLookPreview($model.quickLookURL, in: previewURLs)
    }

    /// The table only reports the requested order. Sorting happens in the query, so it can
    /// cover the whole result set instead of the rows on screen.
    private func apply(_ order: [KeyPathComparator<BrowserRow>]) {
        guard let first = order.first else { return }
        switch first.keyPath {
        case \BrowserRow.name: model.query.sortField = .name
        case \BrowserRow.kindLabel: model.query.sortField = .kind
        case \BrowserRow.fileCount: model.query.sortField = .fileCount
        case \BrowserRow.modified: model.query.sortField = .modified
        default: model.query.sortField = .allocatedSize
        }
        model.query.ascending = first.order == .forward
    }
}

private struct FileBrowserSearchBar: View {
    @Bindable var model: WorkspaceModel

    @State private var isFilterPopoverVisible = false

    private var scopeTitle: String {
        model.query.scope == .currentContents ? "Current Contents" : "Entire Scan"
    }

    private var hasFilters: Bool {
        !model.query.kinds.isEmpty || model.query.minimumSize > 0
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            Picker(scopeTitle, selection: $model.query.scope) {
                Text("Current Contents").tag(FileBrowserQuery.Scope.currentContents)
                Text("Entire Scan").tag(FileBrowserQuery.Scope.entireScan)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            TextField(
                model.query.scope == .currentContents ? "Search current contents" : "Search entire scan",
                text: $model.query.text)
                .textFieldStyle(.plain)
            Button {
                isFilterPopoverVisible.toggle()
            } label: {
                Label("Filters", systemImage: hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .popover(isPresented: $isFilterPopoverVisible, arrowEdge: .bottom) {
                FileBrowserFilters(query: $model.query)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct FileBrowserFilters: View {
    @Binding var query: FileBrowserQuery

    private static let sizes: [(title: String, bytes: Int64)] = [
        ("Any Size", 0), ("1 MB or more", 1_000_000), ("100 MB or more", 100_000_000), ("1 GB or more", 1_000_000_000),
        ("10 GB or more", 10_000_000_000),
    ]

    private func kindBinding(_ kind: FileBrowserQuery.KindFilter) -> Binding<Bool> {
        Binding(
            get: { query.kinds.contains(kind) },
            set: { isOn in
                if isOn { query.kinds.insert(kind) } else { query.kinds.remove(kind) }
            })
    }

    var body: some View {
        Form {
            Section("Kind") {
                Toggle("Folders", isOn: kindBinding(.folder))
                Toggle("Files", isOn: kindBinding(.file))
                Toggle("Packages", isOn: kindBinding(.package))
            }
            Section("Allocated Size") {
                Picker("Allocated Size", selection: $query.minimumSize) {
                    ForEach(Self.sizes, id: \.bytes) { size in
                        Text(size.title).tag(size.bytes)
                    }
                }
                .labelsHidden()
            }
            Button("Clear Filters") {
                query.kinds = []
                query.minimumSize = 0
            }
            .disabled(query.kinds.isEmpty && query.minimumSize == 0)
        }
        .formStyle(.grouped)
        .frame(width: 260, height: 300)
    }
}
