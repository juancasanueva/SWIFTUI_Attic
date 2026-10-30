import SwiftUI

struct InspectorView: View {
    let model: WorkspaceModel
    let tree: FileTree

    private var ids: [NodeID] { model.inspectedIDs.filter(tree.contains) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if ids.count == 1, let id = ids.first {
                    SingleItemDetails(model: model, tree: tree, id: id)
                } else {
                    MultipleItemsSummary(tree: tree, ids: ids)
                }
            }
            .padding(12)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            InspectorActions(model: model, ids: ids)
        }
    }
}

private struct SingleItemDetails: View {
    let model: WorkspaceModel
    let tree: FileTree
    let id: NodeID

    private var node: FileNode { tree[id] }

    private var warnings: [ScanWarning] {
        let path = tree.path(of: id)
        return tree.warnings.filter { $0.path == path || $0.path.hasPrefix(path == "/" ? "/" : path + "/") }
    }

    var body: some View {
        title
        sizes
        if node.warningCount > 0 { warningCard }
        if node.childrenCount > 0 { largestChildren }
        details
    }

    private var title: some View {
        InspectorCard {
            HStack(spacing: 10) {
                Image(systemName: node.kind.symbol)
                    .font(.title2)
                    .foregroundStyle(node.kind.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name).font(.headline).lineLimit(2)
                    Text(tree.path(of: id))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Menu {
                    NodeActionsMenu(model: model, ids: [id])
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Actions")
            }
        }
    }

    private var sizes: some View {
        InspectorCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(node.allocatedSize.byteText).font(.title2.weight(.semibold))
                    Text("Allocated").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    if id != FileTree.rootID {
                        ShareLabel(value: share(of: tree[node.parent].allocatedSize), title: "of parent")
                    }
                    ShareLabel(value: share(of: tree.root.allocatedSize), title: "of scan")
                }
            }
        }
    }

    private func share(of total: Int64) -> Double {
        total > 0 ? Double(node.allocatedSize) / Double(total) : 0
    }

    private var warningCard: some View {
        InspectorCard {
            VStack(alignment: .leading, spacing: 6) {
                Label("Incomplete contents", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("\(warnings.count) \(warnings.count == 1 ? "location" : "locations") in this selection couldn't be read. Its allocated size and contents may be incomplete.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Show Warnings") { model.isWarningsVisible = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private var largestChildren: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Largest Children")
            InspectorCard(padding: 4) {
                VStack(spacing: 0) {
                    ForEach(Array(tree.children(of: id).prefix(5)), id: \.self) { child in
                        Button {
                            model.activate(child)
                        } label: {
                            HStack(spacing: 8) {
                                NodeIcon(kind: tree[child].kind)
                                Text(tree[child].name).lineLimit(1)
                                Spacer()
                                Text(tree[child].allocatedSize.byteText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .padding(8)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Details")
            InspectorCard {
                VStack(spacing: 8) {
                    DetailRow(title: "Kind", value: kindText)
                    if let modified = node.modifiedDate {
                        DetailRow(title: "Modified", value: modified.shortText)
                    }
                    DetailRow(title: "Size on Disk", value: node.allocatedSize.byteText)
                    DetailRow(title: "Logical Size", value: node.logicalSize.byteText)
                    if node.kind.isContainer {
                        DetailRow(title: "Files", value: node.fileCount.formatted())
                        DetailRow(title: "Folders", value: node.folderCount.formatted())
                    }
                    if id != FileTree.rootID {
                        DetailRow(title: "Parent", value: tree[node.parent].name)
                    }
                    DetailRow(title: "Access", value: node.isUnreadable ? "No access" : node.warningCount > 0 ? "Limited" : "Full")
                }
            }
        }
    }

    private var kindText: String {
        switch node.kind {
        case .folder: "Folder"
        case .package: "Package"
        case .file: "File"
        case .symlink: "Alias"
        case .other: "Special File"
        }
    }
}

private struct MultipleItemsSummary: View {
    let tree: FileTree
    let ids: [NodeID]

    private var outermost: [NodeID] {
        let set = Set(ids)
        return ids.filter { !tree.ancestors(of: $0).dropLast().contains(where: set.contains) }
    }

    var body: some View {
        InspectorCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(ids.count) Items Selected").font(.headline)
                Text(outermost.reduce(Int64(0)) { $0 + tree[$1].allocatedSize }.byteText)
                    .font(.title2.weight(.semibold))
                Text("Allocated").font(.caption).foregroundStyle(.secondary)
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Items")
            InspectorCard {
                VStack(spacing: 8) {
                    ForEach(ids.prefix(20), id: \.self) { id in
                        DetailRow(title: tree[id].name, value: tree[id].allocatedSize.byteText)
                    }
                }
            }
        }
    }
}

private struct InspectorActions: View {
    let model: WorkspaceModel
    let ids: [NodeID]

    var body: some View {
        VStack(spacing: 8) {
            Divider()
            Group {
                Button {
                    model.reveal(ids)
                } label: {
                    Label("Reveal in Finder", systemImage: "finder").frame(maxWidth: .infinity)
                }
                Button(role: .destructive) {
                    model.confirmMoveToTrash(ids)
                } label: {
                    Label("Move to Trash…", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .disabled(ids == [FileTree.rootID] || model.isTrashing)
            }
            .controlSize(.large)
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 12)
        .background(.bar)
    }
}

private struct InspectorCard<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
    }
}

private struct SectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title).font(.callout.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 2)
    }
}

private struct ShareLabel: View {
    let value: Double
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            Text(value.percentText).font(.caption.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct DetailRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).lineLimit(1)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).monospacedDigit()
        }
        .font(.callout)
    }
}
