import QuickLook
import SwiftUI

struct ContentView: View {
    @State private var model = WorkspaceModel()
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail
                .inspector(isPresented: $model.isInspectorVisible) {
                    inspector
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                }
        }
        .navigationTitle(model.tree.map { $0[model.focus].name } ?? "Disk")
        .toolbar { WorkspaceToolbar(model: model) }
        .frame(minWidth: 900, minHeight: 600)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.hasDirectoryPath) else { return false }
            model.scan(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .focusedSceneValue(\.workspace, model)
        .modifier(WorkspaceDialogs(model: model))
        .onAppear(perform: applyDebugLaunchArguments)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.phase {
        case .empty:
            EmptyWorkspaceView(model: model)
        case .scanning(let progress):
            ScanningView(model: model, progress: progress)
        case .failed(let message):
            FailedWorkspaceView(model: model, message: message)
        case .ready:
            if let tree = model.tree {
                WorkspaceView(model: model, tree: tree)
            }
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let tree = model.tree, model.phase == .ready {
            InspectorView(model: model, tree: tree)
        } else {
            ContentUnavailableView("No Selection", systemImage: "info.circle")
        }
    }

    /// `-scanPath <folder>` and `-chartMode treemap` start a debug build in a known state.
    private func applyDebugLaunchArguments() {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "chartMode") == "treemap" { model.chartMode = .treemap }
        if let path = UserDefaults.standard.string(forKey: "scanPath") {
            model.scan(URL(fileURLWithPath: path))
        }
        #endif
    }
}

private struct WorkspaceToolbar: ToolbarContent {
    @Bindable var model: WorkspaceModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Back", systemImage: "chevron.left", action: model.goBack)
                .disabled(!model.canGoBack)
            Button("Forward", systemImage: "chevron.right", action: model.goForward)
                .disabled(!model.canGoForward)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Rescan", systemImage: "arrow.clockwise", action: model.rescan)
                .disabled(model.target == nil || model.isScanning)
            Button("Toggle File Browser", systemImage: "rectangle.split.1x2") {
                model.isBrowserVisible.toggle()
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("Chart", selection: $model.chartMode) {
                Label("Sunburst", systemImage: "chart.pie").tag(WorkspaceModel.ChartMode.sunburst)
                Label("Treemap", systemImage: "square.grid.3x3").tag(WorkspaceModel.ChartMode.treemap)
            }
            .pickerStyle(.segmented)
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Toggle Inspector", systemImage: "sidebar.right") {
                model.isInspectorVisible.toggle()
            }
        }
    }
}

private struct WorkspaceDialogs: ViewModifier {
    @Bindable var model: WorkspaceModel

    private var trashTitle: String {
        let count = model.pendingTrash.count
        return "Move \(count) \(count == 1 ? "item" : "items") to the Trash?"
    }

    private var isConfirmingTrash: Binding<Bool> {
        Binding(
            get: { !model.pendingTrash.isEmpty },
            set: { if !$0 { model.pendingTrash = [] } })
    }

    /// A report only needs attention when something could not be moved.
    private var failedReport: Binding<TrashReport?> {
        Binding(
            get: { model.trashReport?.failures.isEmpty == false ? model.trashReport : nil },
            set: { model.trashReport = $0 })
    }

    func body(content: Content) -> some View {
        content
            .quickLookPreview($model.quickLookURL)
            .sheet(isPresented: $model.isDiscardPileVisible) {
                if let tree = model.tree { DiscardPileSheet(model: model, tree: tree) }
            }
            .sheet(isPresented: $model.isWarningsVisible) {
                WarningsSheet(model: model, warnings: model.tree?.warnings ?? [])
            }
            .sheet(item: failedReport) { report in
                TrashReportSheet(report: report)
            }
            .confirmationDialog(trashTitle, isPresented: isConfirmingTrash) {
                Button("Move to Trash", role: .destructive, action: model.performPendingTrash)
            } message: {
                if let tree = model.tree {
                    Text(model.pendingTrash.prefix(5).map { tree[$0].name }.joined(separator: ", "))
                }
            }
    }
}
