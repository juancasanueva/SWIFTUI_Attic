import Foundation
import Observation

/// The scanners Smart Clean runs.
nonisolated enum SmartCleanScanners {
    static let all: [any SuggestionScanner] = [
        DeveloperCachesScanner(), DuplicatesScanner(), InstallersScanner(), MailAttachmentsScanner(),
        BigFilesScanner(), UnusedAppsScanner(), ScreenRecordingsScanner(), OldDownloadsScanner(), LeftoversScanner(),
    ]
}

/// How full the Mac is, by category. Categories fill in as they are measured.
nonisolated struct StorageOverview: Equatable, Sendable {
    var total: Int64
    var available: Int64
    /// /Applications and ~/Applications.
    var apps: Int64?
    /// The home folder without ~/Library, ~/Applications (counted as Apps) and the Trash.
    var yourFiles: Int64?
    /// ~/Library: app data and caches.
    var other: Int64?
    var trash: Int64?

    var used: Int64 { max(0, total - available) }

    /// Everything else that is used, once every category is known.
    var system: Int64? {
        guard let apps, let yourFiles, let other, let trash else { return nil }
        return max(0, used - apps - yourFiles - other - trash)
    }

    static func capacity(of volume: URL) -> (total: Int64, available: Int64)? {
        let values = try? volume.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        guard let total = values?.volumeTotalCapacity, let available = values?.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return (Int64(total), available)
    }

    @concurrent static func measureApps(_ environment: CleanEnvironment) async -> Int64 {
        environment.applicationFolders.reduce(0) { $0 + CleanWalker.size(of: $1) }
    }

    @concurrent static func measureYourFiles(_ environment: CleanEnvironment) async -> Int64 {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: environment.home, includingPropertiesForKeys: nil)) ?? []
        return children
            .filter { !["Library", "Applications", ".Trash"].contains($0.lastPathComponent) }
            .reduce(0) { Task.isCancelled ? $0 : $0 + CleanWalker.size(of: $1) }
    }

    @concurrent static func measureOther(_ environment: CleanEnvironment) async -> Int64 {
        CleanWalker.size(of: environment.library)
    }

    @concurrent static func measureTrash(_ environment: CleanEnvironment) async -> Int64 {
        CleanWalker.size(of: environment.trash)
    }
}

/// The Smart Clean page: storage, nine suggestions, ticks, Clean (to the Trash, one Undo
/// step) and Empty Trash (always asks).
@Observable
final class SmartCleanModel {
    let actions: TrashActions
    @ObservationIgnored private let scanners: [any SuggestionScanner]
    @ObservationIgnored private let environment: @Sendable () -> CleanEnvironment
    @ObservationIgnored private let measuresStorage: Bool
    /// The volume's total and available bytes (injectable so tests control when it arrives).
    typealias CapacityReader = @Sendable (URL) async -> (total: Int64, available: Int64)?
    @ObservationIgnored private let capacity: CapacityReader
    /// Bumped per scan, so a slow, older scan never overwrites a newer one.
    @ObservationIgnored private var generation = 0
    /// The running scan, cancelled when a newer one starts so it stops working.
    @ObservationIgnored private var currentScan: Task<Void, Never>?
    /// Items the user ticked or unticked in this scan: a later suggestion listing one again
    /// leaves the user's choice alone. Any other item starts ticked when a suggestion that
    /// lists it ticks by default, whichever finishes first.
    @ObservationIgnored private var changedByUser: Set<URL> = []
    /// Set by `requestEmptyTrash`, cleared by cancel or confirm. Separate from the dialog's
    /// `isConfirmingEmptyTrash`, which SwiftUI resets before the button's action runs.
    @ObservationIgnored private var emptyTrashRequested = false

    private(set) var storage: StorageOverview?
    /// Every kind, in display order, once a scan started.
    private(set) var suggestions: [CleanSuggestion] = []
    private(set) var scanningKinds: Set<SuggestionKind> = []
    private(set) var failures: [SuggestionKind: String] = [:]
    var ticked: Set<URL> = []
    private(set) var isCleaning = false
    var isConfirmingEmptyTrash = false
    var alertMessage: String?

    init(
        actions: TrashActions,
        scanners: [any SuggestionScanner] = SmartCleanScanners.all,
        environment: @escaping @Sendable () -> CleanEnvironment = CleanEnvironment.live,
        measureStorage: Bool = true,
        capacity: @escaping CapacityReader = { StorageOverview.capacity(of: $0) }
    ) {
        self.actions = actions
        self.scanners = scanners
        self.environment = environment
        self.measuresStorage = measureStorage
        self.capacity = capacity
    }

    var isScanning: Bool { !scanningKinds.isEmpty }

    func suggestion(_ kind: SuggestionKind) -> CleanSuggestion? {
        suggestions.first { $0.kind == kind }
    }

    func suggestions(in group: CleanGroup) -> [CleanSuggestion] {
        suggestions.filter { $0.kind.group == group }
    }

    // MARK: Ticks

    func isTicked(_ url: URL) -> Bool { ticked.contains(url.canonical) }

    func toggle(_ url: URL) {
        let url = url.canonical
        changedByUser.insert(url)
        if ticked.contains(url) { ticked.remove(url) } else { ticked.insert(url) }
    }

    func setAll(_ kind: SuggestionKind, ticked isTicked: Bool) {
        let urls = suggestion(kind)?.candidates.map(\.url) ?? []
        changedByUser.formUnion(urls)
        if isTicked { ticked.formUnion(urls) } else { ticked.subtract(urls) }
    }

    /// Ticked items that are really listed, without those inside another ticked item (trashing
    /// the folder takes them along), each with its size. A duplicate set never loses every
    /// copy: when all of them would go, the kept copy stays (or, when a ticked folder takes it,
    /// another copy of the set).
    var itemsToClean: [(url: URL, bytes: Int64)] {
        var sizes: [URL: Int64] = [:]
        for candidate in suggestions.flatMap(\.candidates) where ticked.contains(candidate.url) {
            sizes[candidate.url] = sizes[candidate.url] ?? candidate.bytes
        }
        let paths = Set(sizes.keys.map(\.path))
        var items = sizes.filter { url, _ in
            // Walk up the parents: any ticked ancestor already covers this item.
            var parent = url.deletingLastPathComponent()
            while parent.path != "/", parent.pathComponents.count > 1 {
                if paths.contains(parent.canonical.path) { return false }
                parent = parent.deletingLastPathComponent()
            }
            return true
        }
        keepOneCopyOfEachDuplicateSet(&items)
        return items
            .map { (url: $0.key, bytes: $0.value) }
            .sorted { $0.url.path < $1.url.path }
    }

    /// Removes from `items` (top-level items, none inside another) one copy of every duplicate
    /// set that would otherwise go entirely.
    private func keepOneCopyOfEachDuplicateSet(_ items: inout [URL: Int64]) {
        func goes(_ url: URL) -> Bool {
            items.keys.contains { $0 == url || url.path.hasPrefix($0.path + "/") }
        }
        var sets: [URL: [URL]] = [:]
        for candidate in suggestion(.duplicates)?.candidates ?? [] {
            if let kept = candidate.keptCopy { sets[kept, default: []].append(candidate.url) }
        }
        for (kept, copies) in sets.sorted(by: { $0.key.path < $1.key.path }) {
            let members = [kept] + copies.sorted { $0.path < $1.path }
            guard members.allSatisfy(goes) else { continue }
            // Only an item trashed by itself can be spared; one inside a ticked folder can't.
            if let spared = members.first(where: { items[$0] != nil }) { items[spared] = nil }
        }
    }

    /// "You could free about …".
    var tickedBytes: Int64 { itemsToClean.reduce(0) { $0 + $1.bytes } }

    // MARK: Scanning

    /// Measures storage and runs every scanner again; ticks go back to their defaults. Cancels
    /// the scan still running; cancelling the caller (closing the window) cancels this one.
    func lookAgain() async {
        currentScan?.cancel()
        let scan = Task { await self.scan() }
        currentScan = scan
        await withTaskCancellationHandler {
            await scan.value
        } onCancel: {
            scan.cancel()
        }
    }

    /// Cancels the running scan, whoever started it (the window's task, the Look Again or
    /// Clean button). Called when the window closes.
    func stopScanning() {
        currentScan?.cancel()
    }

    private func scan() async {
        generation += 1
        let generation = generation
        let environment = await Self.make(self.environment)
        guard generation == self.generation else { return }
        suggestions = SuggestionKind.allCases.map { CleanSuggestion(kind: $0, candidates: []) }
        failures = [:]
        ticked = []
        changedByUser = []
        scanningKinds = Set(scanners.map(\.kind))
        async let storage: Void = measureStorage(environment, generation: generation)
        await withTaskGroup(of: (SuggestionKind, Result<[CleanCandidate], any Error>).self) { group in
            for scanner in scanners {
                group.addTask {
                    do {
                        return (scanner.kind, .success(try await scanner.scan(environment)))
                    } catch {
                        return (scanner.kind, .failure(error))
                    }
                }
            }
            for await (kind, result) in group {
                guard generation == self.generation else { continue }
                scanningKinds.remove(kind)
                switch result {
                case .success(let found):
                    show(found, for: kind)
                case .failure(let error):
                    if !(error is CancellationError) { failures[kind] = error.localizedDescription }
                }
            }
        }
        await storage
    }

    private func show(_ found: [CleanCandidate], for kind: SuggestionKind) {
        guard let index = suggestions.firstIndex(where: { $0.kind == kind }) else { return }
        // Never offer what isn't there (anymore); biggest first.
        let present = found
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
            .sorted { $0.bytes > $1.bytes }
        suggestions[index].candidates += present
        for candidate in present where !changedByUser.contains(candidate.url) {
            if candidate.isTickedByDefault ?? (kind.group == .safe) { ticked.insert(candidate.url) }
        }
    }

    private func measureStorage(_ environment: CleanEnvironment, generation: Int) async {
        guard measuresStorage else { return }
        guard let capacity = await capacity(environment.home) else { return }
        // A newer scan may have begun meanwhile: never reset its overview.
        guard generation == self.generation else { return }
        storage = StorageOverview(total: capacity.total, available: capacity.available)
        async let apps = StorageOverview.measureApps(environment)
        async let files = StorageOverview.measureYourFiles(environment)
        async let other = StorageOverview.measureOther(environment)
        async let trash = StorageOverview.measureTrash(environment)
        let trashBytes = await trash
        if generation == self.generation { storage?.trash = trashBytes }
        let appBytes = await apps
        if generation == self.generation { storage?.apps = appBytes }
        let otherBytes = await other
        if generation == self.generation { storage?.other = otherBytes }
        let fileBytes = await files
        if generation == self.generation { storage?.yourFiles = fileBytes }
    }

    @concurrent private static func make(_ environment: @Sendable () -> CleanEnvironment) async -> CleanEnvironment {
        environment()
    }

    // MARK: Cleaning

    /// Moves the ticked items to the Trash as one undoable step, then looks again. Items gone
    /// since the scan are skipped, so they don't stop the rest.
    func clean() async {
        let urls = itemsToClean.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
        // Nothing goes until every suggestion is in: a scan still running could list more.
        guard !urls.isEmpty, !isCleaning, !isScanning else { return }
        isCleaning = true
        defer { isCleaning = false }
        do {
            try await actions.trash(urls, actionName: "Smart Clean")
        } catch {
            alertMessage = error.localizedDescription
        }
        await lookAgain()
    }

    /// Empty Trash always asks first (`isConfirmingEmptyTrash` shows the dialog).
    func requestEmptyTrash() {
        emptyTrashRequested = true
        isConfirmingEmptyTrash = true
    }

    func cancelEmptyTrash() {
        emptyTrashRequested = false
        isConfirmingEmptyTrash = false
    }

    /// Deletes the Trash's contents for good; only after `requestEmptyTrash`. TrashActions drops
    /// the undo steps that moved items there (only those) once anything was deleted, also when
    /// emptying failed partway.
    func confirmEmptyTrash() async {
        guard emptyTrashRequested else { return }
        emptyTrashRequested = false
        isConfirmingEmptyTrash = false
        let environment = await Self.make(self.environment)
        do {
            try await actions.emptyTrash(environment.trash)
        } catch {
            alertMessage = error.localizedDescription
        }
        if measuresStorage {
            let trash = await StorageOverview.measureTrash(environment)
            storage?.trash = trash
            if let capacity = await capacity(environment.home) { storage?.available = capacity.available }
        }
    }
}
