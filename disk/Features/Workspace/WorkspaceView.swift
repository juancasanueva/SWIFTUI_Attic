import SwiftUI

struct WorkspaceView: View {
    let model: WorkspaceModel
    let tree: FileTree

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeaderView(model: model, tree: tree)
            Divider()
            if model.isBrowserVisible {
                VSplitView {
                    ChartAreaView(model: model, tree: tree)
                        .frame(minHeight: 240, idealHeight: 480)
                    FileBrowserView(model: model)
                        .frame(minHeight: 160, idealHeight: 340)
                }
            } else {
                ChartAreaView(model: model, tree: tree)
            }
        }
    }
}

struct WorkspaceHeaderView: View {
    let model: WorkspaceModel
    let tree: FileTree

    private var focusNode: FileNode { tree[model.focus] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(focusNode.name).font(.title2.weight(.semibold)).lineLimit(1)
                    Text(tree.path(of: model.focus))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 24)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Last Updated").font(.caption).foregroundStyle(.secondary)
                    Text(tree.scannedAt.shortText).font(.callout.weight(.medium))
                }
            }
            HStack(alignment: .bottom) {
                breadcrumbs
                Spacer(minLength: 24)
                HeaderStat(title: "Scanned", value: tree.root.allocatedSize.byteText)
                HeaderStat(title: "Files", value: tree.root.fileCount.formatted())
                HeaderStat(title: "Folders", value: tree.root.folderCount.formatted())
                Button {
                    model.isWarningsVisible = true
                } label: {
                    HeaderStat(title: "Warnings", value: tree.root.warningCount.formatted())
                }
                .buttonStyle(.plain)
                .disabled(tree.warnings.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                let chain = tree.ancestors(of: model.focus)
                ForEach(chain, id: \.self) { id in
                    Button(tree[id].name) { model.navigate(to: id) }
                        .buttonStyle(.plain)
                        .fontWeight(id == model.focus ? .semibold : .regular)
                        .foregroundStyle(id == model.focus ? .primary : .secondary)
                    if id != model.focus {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .scrollIndicators(.never)
        .font(.callout)
    }
}

private struct HeaderStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
        }
        .frame(minWidth: 72, alignment: .leading)
    }
}

// MARK: - States without a finished scan

struct EmptyWorkspaceView: View {
    let model: WorkspaceModel

    var body: some View {
        ContentUnavailableView {
            Label("Choose a Location", systemImage: "chart.pie")
        } description: {
            Text("Pick a location in the sidebar, or drop a folder here to see where your space went.")
        } actions: {
            Button("Choose Folder…", action: model.chooseFolder)
                .buttonStyle(.borderedProminent)
        }
    }
}

struct ScanningView: View {
    let model: WorkspaceModel
    let progress: ScanProgress

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Scanning \(model.target?.lastPathComponent ?? "")").font(.title2.weight(.semibold))
            HStack(spacing: 24) {
                HeaderStat(title: "Scanned", value: progress.allocatedBytes.byteText)
                HeaderStat(title: "Files", value: progress.filesScanned.formatted())
                HeaderStat(title: "Folders", value: progress.foldersScanned.formatted())
            }
            Text(progress.currentPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 480)
            Button("Stop Scan", action: model.cancelScan)
                .keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FailedWorkspaceView: View {
    let model: WorkspaceModel
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Scan Failed", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Choose Folder…", action: model.chooseFolder)
        }
    }
}

// MARK: - Warnings

struct WarningsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let model: WorkspaceModel
    let warnings: [ScanWarning]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Locations That Couldn't Be Read").font(.title3.weight(.semibold))
            Text("Their contents are missing from this scan. Full Disk Access lets the app read most of them; rescan after granting it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            List(warnings, id: \.path) { warning in
                VStack(alignment: .leading) {
                    Text(warning.path).lineLimit(1).truncationMode(.middle)
                    Text(warning.message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 240)
            HStack {
                Button("Open Full Disk Access Settings", action: model.openFullDiskAccessSettings)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 560)
    }
}
