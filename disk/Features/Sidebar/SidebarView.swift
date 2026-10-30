import Observation
import SwiftUI

@MainActor
@Observable
final class RecentScansStore {
    private static let key = "recentScans"
    private static let limit = 8

    private(set) var paths: [String]

    init() {
        paths = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
    }

    func record(_ url: URL) {
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        paths = Array(paths.prefix(Self.limit))
        UserDefaults.standard.set(paths, forKey: Self.key)
    }

    func remove(_ path: String) {
        paths.removeAll { $0 == path }
        UserDefaults.standard.set(paths, forKey: Self.key)
    }
}

struct SmartLocation: Identifiable, Hashable {
    let url: URL
    let name: String
    let symbol: String
    let detail: String?

    var id: String { url.path }

    static func drives() -> [SmartLocation] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeIsRemovableKey]
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [])
            .map { url -> SmartLocation in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let free = (values?.volumeAvailableCapacityForImportantUsage ?? 0).formatted(.byteCount(style: .file))
                let total = Int64(values?.volumeTotalCapacity ?? 0).formatted(.byteCount(style: .file))
                return SmartLocation(
                    url: url, name: values?.volumeName ?? url.lastPathComponent,
                    symbol: values?.volumeIsRemovable == true ? "externaldrive.fill" : "internaldrive.fill",
                    detail: "\(free) free of \(total)")
            }
    }

    /// The standard folders of the current user.
    static func folders() -> [SmartLocation] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        func folder(_ name: String, _ symbol: String, _ url: URL) -> SmartLocation {
            SmartLocation(url: url, name: name, symbol: symbol, detail: nil)
        }
        return [
            folder("Home", "house.fill", home),
            folder("Desktop", "menubar.dock.rectangle", home.appending(path: "Desktop")),
            folder("Documents", "doc.fill", home.appending(path: "Documents")),
            folder("Downloads", "arrow.down.circle.fill", home.appending(path: "Downloads")),
            folder("Library", "books.vertical.fill", home.appending(path: "Library")),
            folder("Applications", "square.grid.2x2.fill", URL(fileURLWithPath: "/Applications")),
        ]
    }
}

struct SidebarView: View {
    let model: WorkspaceModel

    @State private var drives = SmartLocation.drives()
    @State private var folders = SmartLocation.folders()

    private var recentPaths: [String] {
        let smart = Set((drives + folders).map(\.url.path))
        return model.recents.paths.filter { !smart.contains($0) }
    }

    private var selectedPath: Binding<String?> {
        Binding(
            get: { model.target?.path },
            set: { path in
                if let path, path != model.target?.path { model.scan(URL(fileURLWithPath: path)) }
            })
    }

    var body: some View {
        List(selection: selectedPath) {
            locationSection("Drives", drives)
            locationSection("Folders", folders)
            if !recentPaths.isEmpty {
                Section {
                    ForEach(recentPaths, id: \.self) { path in
                        SidebarRow(title: (path as NSString).lastPathComponent, detail: nil, symbol: "folder.fill")
                            .tag(path)
                            .help(path)
                            .contextMenu {
                                Button("Remove from Recents") { model.recents.remove(path) }
                            }
                    }
                } header: {
                    SidebarSectionTitle("Recent Scans")
                }
            }
            ChooseFolderRow(action: model.chooseFolder)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            DiscardPileFooter(model: model)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            drives = SmartLocation.drives()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            drives = SmartLocation.drives()
        }
    }
}

private func locationSection(_ title: String, _ locations: [SmartLocation]) -> some View {
    Section {
        ForEach(locations) { location in
            SidebarRow(title: location.name, detail: location.detail, symbol: location.symbol)
                .tag(location.url.path)
                .help(location.url.path)
        }
    } header: {
        SidebarSectionTitle(title)
    }
}

private struct SidebarSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title).font(.title2.weight(.semibold))
    }
}

private struct ChooseFolderRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Choose Folder…", systemImage: "plus.circle")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(.rect(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.secondary.opacity(0.5))
                }
        }
        .buttonStyle(.plain)
        .selectionDisabled()
        .listRowSeparator(.hidden)
        .padding(.top, 6)
    }
}

private struct SidebarRow: View {
    let title: String
    let detail: String?
    let symbol: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } icon: {
            Image(systemName: symbol)
        }
        .padding(.vertical, 2)
    }
}

private struct DiscardPileFooter: View {
    let model: WorkspaceModel

    private var detail: String {
        guard !model.discardPile.isEmpty, let plan = model.trashPlan else { return "No items marked" }
        let count = plan.moves.count + plan.refusals.count
        return "\(count) \(count == 1 ? "item" : "items") · \(plan.bytes.byteText)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                model.isDiscardPileVisible = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "checklist")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Discard Pile").font(.callout.weight(.medium))
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(model.discardPile.isEmpty)
        }
    }
}
