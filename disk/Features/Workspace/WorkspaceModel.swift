import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

nonisolated struct BrowserRow: Identifiable, Sendable {
    let id: NodeID
    let name: String
    let subtitle: String?
    let allocatedSize: Int64
    let kind: NodeKind
    let kindLabel: String
    let fileCount: Int32
    let modified: TimeInterval
}

struct TrashReport: Identifiable {
    let id = UUID()
    let movedBytes: Int64
    let failures: [TrashFailure]
}

@MainActor
@Observable
final class WorkspaceModel {
    enum Phase: Equatable {
        case empty
        case scanning(ScanProgress)
        case ready
        case failed(String)
    }

    enum ChartMode: Hashable {
        case sunburst, treemap
    }

    let recents = RecentScansStore()

    private(set) var phase = Phase.empty
    private(set) var target: URL?
    private(set) var tree: FileTree?
    /// Changes whenever the tree contents change, so layouts know to recompute.
    private(set) var revision = 0
    private(set) var focus = FileTree.rootID
    private var backStack: [NodeID] = []
    private var forwardStack: [NodeID] = []

    var selection: Set<NodeID> = []
    var hoveredID: NodeID?
    var hoverLocation: CGPoint = .zero
    var chartMode = ChartMode.sunburst
    var isBrowserVisible = true
    var isInspectorVisible = true

    var query = FileBrowserQuery()
    private(set) var browserRows: [BrowserRow] = []

    private(set) var discardPile = DiscardPile()
    var isDiscardPileVisible = false
    var pendingTrash: [NodeID] = []
    var trashReport: TrashReport?
    private(set) var isTrashing = false
    var isWarningsVisible = false
    var quickLookURL: URL?

    @ObservationIgnored private var scanTask: Task<Void, Never>?

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { focus != FileTree.rootID }
    var isScanning: Bool {
        if case .scanning = phase { true } else { false }
    }

    // MARK: Scanning

    func scan(_ url: URL) {
        scanTask?.cancel()
        // A rescan of the same location keeps the user's place and their discard pile.
        let carried = url.path == target?.path ? carriedState() : nil
        target = url
        tree = nil
        // Node IDs only mean something within one scan, so nothing may outlive the old tree.
        pendingTrash = []
        isDiscardPileVisible = false
        resetNavigation()
        discardPile.removeAll()
        phase = .scanning(ScanProgress())
        recents.record(url)

        scanTask = Task { [weak self] in
            let (stream, continuation) = AsyncStream.makeStream(of: ScanProgress.self, bufferingPolicy: .bufferingNewest(1))
            let updates = Task { [weak self] in
                for await progress in stream { self?.apply(progress) }
            }
            defer { updates.cancel() }
            do {
                let tree = try await FileScanner().scan(root: url) { continuation.yield($0) }
                continuation.finish()
                if !Task.isCancelled { self?.finishScan(tree, carried: carried) }
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish()
                if !Task.isCancelled { self?.failScan(error) }
            }
        }
    }

    func rescan() {
        if let target { scan(target) }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        target = nil
        phase = .empty
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url { scan(url) }
    }

    private func apply(_ progress: ScanProgress) {
        if isScanning { phase = .scanning(progress) }
    }

    private func failScan(_ error: Error) {
        phase = .failed(Self.describe(error))
    }

    private func finishScan(_ tree: FileTree, carried: CarriedState?) {
        self.tree = tree
        revision += 1
        if let carried {
            focus = carried.focusPath.flatMap(tree.node(atPath:)) ?? FileTree.rootID
            for path in carried.pilePaths {
                if let id = tree.node(atPath: path) { discardPile.add(id) }
            }
        }
        phase = .ready
    }

    private struct CarriedState {
        let focusPath: String?
        let pilePaths: [String]
    }

    private func carriedState() -> CarriedState? {
        guard let tree else { return nil }
        return CarriedState(focusPath: tree.path(of: focus), pilePaths: discardPile.items.map(tree.path(of:)))
    }

    private func resetNavigation() {
        focus = FileTree.rootID
        backStack = []
        forwardStack = []
        selection = []
        hoveredID = nil
        browserRows = []
        query.text = ""
    }

    private static func describe(_ error: Error) -> String {
        if case let FileScanner.Failure.cannotRead(path, reason) = error {
            return "\(path) can't be read: \(reason)."
        }
        return error.localizedDescription
    }

    // MARK: Navigation

    func navigate(to id: NodeID) {
        guard let tree, tree[id].kind.isContainer, id != focus else { return }
        backStack.append(focus)
        forwardStack = []
        moveFocus(to: id)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(focus)
        moveFocus(to: previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(focus)
        moveFocus(to: next)
    }

    func goUp() {
        guard let tree, canGoUp else { return }
        navigate(to: tree[focus].parent)
    }

    private func moveFocus(to id: NodeID) {
        focus = id
        selection = []
        hoveredID = nil
    }

    /// A folder drills in, anything else opens in Quick Look.
    func activate(_ id: NodeID) {
        guard let tree else { return }
        if tree[id].kind == .folder || (tree[id].kind == .package && tree.children(of: id).count > 0) {
            navigate(to: id)
        } else {
            quickLookURL = tree.url(of: id)
        }
    }

    /// The selection when there is one, otherwise the folder on screen.
    var inspectedIDs: [NodeID] {
        selection.isEmpty ? [focus] : selection.sorted()
    }

    // MARK: File browser

    struct BrowserKey: Hashable {
        let query: FileBrowserQuery
        let focus: NodeID
        let revision: Int
    }

    var browserKey: BrowserKey { BrowserKey(query: query, focus: focus, revision: revision) }

    func refreshBrowser() async {
        guard let tree else { return }
        // Let fast typing settle before walking a large tree.
        if !query.text.isEmpty {
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard !Task.isCancelled else { return }
        let startRevision = revision
        let rows = try? await Self.makeRows(query: query, tree: tree, focus: focus)
        // Row IDs belong to the tree they came from, so late results must not outlive it.
        if let rows, !Task.isCancelled, revision == startRevision, self.tree != nil {
            browserRows = rows
        }
    }

    @concurrent
    private nonisolated static func makeRows(query: FileBrowserQuery, tree: FileTree, focus: NodeID) async throws -> [BrowserRow] {
        var labels: [String: String] = [:]
        return try query.results(in: tree, focus: focus).map { id in
            let node = tree[id]
            let label: String
            switch node.kind {
            case .folder: label = "Folder"
            case .package: label = node.name.hasSuffix(".app") ? "Application" : "Package"
            case .symlink: label = "Alias"
            case .other: label = "Special File"
            case .file:
                let fileExtension = (node.name as NSString).pathExtension.lowercased()
                if let cached = labels[fileExtension] {
                    label = cached
                } else {
                    label = UTType(filenameExtension: fileExtension)?.localizedDescription ?? "Document"
                    labels[fileExtension] = label
                }
            }
            return BrowserRow(
                id: id, name: node.name, subtitle: subtitle(for: id, in: tree, query: query, focus: focus),
                allocatedSize: node.allocatedSize, kind: node.kind, kindLabel: label,
                fileCount: node.fileCount, modified: node.modified)
        }
    }

    private nonisolated static func subtitle(for id: NodeID, in tree: FileTree, query: FileBrowserQuery, focus: NodeID) -> String? {
        if query.hasCriteria, tree[id].parent != focus, id != FileTree.rootID {
            return tree.path(of: tree[id].parent)
        }
        return tree[id].warningCount > 0 ? "Limited access" : nil
    }

    // MARK: Discard pile

    func addToDiscardPile(_ ids: some Sequence<NodeID>) {
        for id in ids { discardPile.add(id) }
    }

    func removeFromDiscardPile(_ id: NodeID) {
        discardPile.remove(id)
    }

    func clearDiscardPile() {
        discardPile.removeAll()
    }

    func confirmMoveToTrash(_ ids: [NodeID]) {
        pendingTrash = ids
    }

    var trashPlan: TrashPlan? {
        tree.map { discardPile.plan(in: $0, policy: TrashSafetyPolicy()) }
    }

    func performPendingTrash() {
        let requested = pendingTrash
        pendingTrash = []
        guard let tree, !requested.isEmpty, !isTrashing else { return }
        var request = DiscardPile()
        for id in requested { request.add(id) }
        isTrashing = true
        let startRevision = revision
        Task {
            let outcome = await Self.moveToTrash(request, in: tree)
            isTrashing = false
            // A scan that started meanwhile has newer data than this outcome, but anything
            // that could not be moved still has to be reported.
            if revision == startRevision, phase == .ready {
                apply(outcome)
            } else {
                trashReport = TrashReport(movedBytes: outcome.movedBytes, failures: outcome.failures)
            }
        }
    }

    @concurrent
    private nonisolated static func moveToTrash(_ pile: DiscardPile, in tree: FileTree) async -> TrashOutcome {
        pile.moveToTrash(in: tree, policy: TrashSafetyPolicy()) { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    private func apply(_ outcome: TrashOutcome) {
        tree = outcome.tree
        revision += 1
        for id in discardPile.items where !outcome.tree.contains(id) { discardPile.remove(id) }
        selection = selection.filter(outcome.tree.contains)
        while !outcome.tree.contains(focus) { focus = outcome.tree[focus].parent }
        backStack.removeAll { !outcome.tree.contains($0) }
        forwardStack.removeAll { !outcome.tree.contains($0) }
        hoveredID = nil
        trashReport = TrashReport(movedBytes: outcome.movedBytes, failures: outcome.failures)
    }

    // MARK: System actions

    func reveal(_ ids: [NodeID]) {
        guard let tree else { return }
        NSWorkspace.shared.activateFileViewerSelecting(ids.map(tree.url(of:)))
    }

    func open(_ id: NodeID) {
        guard let tree else { return }
        NSWorkspace.shared.open(tree.url(of: id))
    }

    func copyPaths(_ ids: [NodeID]) {
        guard let tree else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ids.map(tree.path(of:)).joined(separator: "\n"), forType: .string)
    }

    func quickLook(_ id: NodeID) {
        quickLookURL = tree?.url(of: id)
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
