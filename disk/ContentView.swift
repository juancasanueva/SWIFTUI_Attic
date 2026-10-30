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
        .toolbar(removing: .title)
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
        ToolbarItemGroup(placement: .principal) {
            Button("Rescan", systemImage: "arrow.clockwise", action: model.rescan)
                .disabled(model.target == nil || model.isScanning)
            Button("Toggle File Browser", systemImage: "rectangle.split.1x2") {
                model.isBrowserVisible.toggle()
            }
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

    /// The dialog is the last look before files move, so it states what will really happen.
    private var trashPlan: TrashPlan? {
        model.tree.map { TrashPlan(items: model.pendingTrash, in: $0, policy: TrashSafetyPolicy()) }
    }

    private var trashTitle: String {
        guard let plan = trashPlan, !plan.moves.isEmpty else { return "This Can't Be Moved to the Trash" }
        let count = plan.moves.count
        return "Move \(count) \(count == 1 ? "item" : "items") (\(plan.bytes.byteText)) to the Trash?"
    }

    private var trashMessage: String {
        guard let tree = model.tree, let plan = trashPlan else { return "" }
        let moving = plan.moves.prefix(5).map { tree[$0].name }.joined(separator: ", ")
        let more = plan.moves.count > 5 ? " and \(plan.moves.count - 5) more" : ""
        let refused = plan.refusals.prefix(5).map { "\(tree[$0.id].name): \($0.reason)" }.joined(separator: "\n")
        return [moving + more, refused.isEmpty ? "" : "Won't be moved:\n" + refused]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
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
            .sheet(isPresented: $model.isWarningsVisible) {
                WarningsSheet(model: model, warnings: model.tree?.warnings ?? [])
            }
            .sheet(item: failedReport) { report in
                TrashReportSheet(report: report)
            }
            .confirmationDialog(trashTitle, isPresented: isConfirmingTrash) {
                if trashPlan?.moves.isEmpty == false {
                    Button("Move to Trash", role: .destructive, action: model.performPendingTrash)
                }
            } message: {
                Text(trashMessage)
            }
    }
}
