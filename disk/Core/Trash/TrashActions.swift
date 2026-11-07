import Foundation

nonisolated enum TrashActionError: LocalizedError, Equatable {
    case notTheTrash
    case movedWhileEmptying(String)

    var errorDescription: String? {
        switch self {
        case .notTheTrash: "Only the Trash can be emptied."
        case .movedWhileEmptying(let name): "“\(name)” was moved while the Trash was being emptied, so what was left of it was kept."
        }
    }
}

/// Identity for the undo steps that need items in the Trash, which emptying it deletes.
private final class TrashUndoTarget {}

/// One item going from `from` to `to` (a trip to the Trash, or back out of it).
nonisolated struct FileTransfer: Equatable, Sendable {
    let from: URL
    let to: URL
    var reversed: FileTransfer { FileTransfer(from: to, to: from) }
}

/// What a batch managed to do before it stopped, and why it stopped.
nonisolated struct BatchResult: Sendable {
    var done: [FileTransfer] = []
    var error: (any Error)?
}

/// Items one trash step (or its undo) actually relocated.
private final class RelocationRecord {
    var transfers: [FileTransfer]
    init(transfers: [FileTransfer]) { self.transfers = transfers }
}

/// Moves items to the Trash as undoable steps and empties the Trash. Disk work runs off the
/// main actor, and every operation, including undo and redo work, runs on one serial queue so
/// batches never interleave. Each completed step registers its inverse on `undoManager`;
/// failures of undo/redo work go to `onBackgroundError`.
final class TrashActions {
    var undoManager: UndoManager?
    /// Receives errors from undo/redo work, which has no caller to throw to.
    var onBackgroundError: ((String) -> Void)?
    /// Tail of the serial queue of disk work.
    private var lastWork: Task<Void, Never>?
    /// Operations waiting behind the running one.
    private(set) var queuedOperations = 0
    /// The undo target of steps that need items in the Trash (bringing them back out), so
    /// emptying the Trash can drop exactly those.
    private let trashUndoTarget = TrashUndoTarget()

    /// Moves one item to the Trash and returns where it went (`nil` when unknown).
    typealias Trasher = @Sendable (URL) throws -> URL?
    nonisolated private let trasher: Trasher
    /// The Trash that `trasher` fills and Empty Trash empties. Only paths inside it count as
    /// the Trash; other folders named ".Trash" and other volumes' ".Trashes" don't.
    let trashFolder: URL
    /// The listing and parent checks Empty Trash makes; tests make them fail or act in between.
    private let trashWalk: TrashWalk

    init(
        trashFolder: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash"),
        trasher: @escaping Trasher = TrashActions.systemTrasher,
        trashWalk: TrashWalk = .system
    ) {
        self.trashFolder = trashFolder.canonical
        self.trasher = trasher
        self.trashWalk = trashWalk
    }

    /// The system's Move to Trash.
    nonisolated static let systemTrasher: Trasher = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    /// Waits until all queued work has finished.
    func waitForPendingWork() async {
        await lastWork?.value
    }

    // MARK: - Trash

    /// Moves items to the Trash as one undo step named `actionName`.
    func trash(_ urls: [URL], actionName: String = "Move to Trash") async throws {
        try await serialized {
            let result = await Self.performTrash(urls, trasher: self.trasher)
            let needsTrash = await Self.trashNeeds(result.done, trash: self.trashFolder)
            if !result.done.isEmpty { self.registerRelocationUndo(actionName, result.done, needsTrash: needsTrash) }
            if let error = result.error { throw error }
        }
    }

    /// Drops the undo steps that need items in the Trash, once emptying it deleted them; every
    /// other undo step (renames, moves, copies elsewhere…) stays.
    func dropTrashUndo() {
        undoManager?.removeAllActions(withTarget: trashUndoTarget)
    }

    /// Permanently deletes everything in `trash`. Not undoable, so callers must ask first.
    /// Refuses anything but `trashFolder`, and it only when it is a real folder: a link named
    /// ".Trash" would otherwise empty the folder it points to. Afterwards the undo steps that
    /// need items in the Trash are dropped, unless emptying stopped before deleting anything
    /// (then those items are all still there).
    func emptyTrash(_ trash: URL) async throws {
        guard trash.canonical == trashFolder else { throw TrashActionError.notTheTrash }
        // Checked inside the queued work, right before deleting: the Trash may change while
        // earlier operations run.
        try await serialized {
            let result = await Self.performEmptyTrash(trash, walk: self.trashWalk)
            // A Trash already empty (emptied in Finder) also leaves those steps nothing to restore.
            if result.deletedSomething || result.error == nil { self.dropTrashUndo() }
            if let error = result.error { throw error }
        }
    }

    /// The folder's device and inode, or `nil` when `url` isn't a real folder. `lstat` never
    /// follows a final link.
    private nonisolated static func realFolderIdentity(_ url: URL) -> (dev_t, ino_t)? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return (info.st_dev, info.st_ino)
    }

    /// What emptying did so far: whether anything at all was deleted, and the first failure.
    private nonisolated struct Deletion {
        var deletedSomething = false
        var error: (any Error)?

        mutating func fail(_ code: Int32, path: String) {
            guard code != ENOENT else { return }   // already gone
            error = error ?? TrashActions.removalError(code, path: path)
        }
    }

    /// Deletes the Trash's contents relative to the folder opened once (never through a link):
    /// a link swapped in for the Trash, or for a folder inside it, is never followed. Goes on
    /// past items it can't delete, and stops when the Trash's path no longer leads to it.
    @concurrent private nonisolated static func performEmptyTrash(
        _ trash: URL, walk: TrashWalk
    ) async -> (deletedSomething: Bool, error: (any Error)?) {
        guard let identity = realFolderIdentity(trash) else { return (false, TrashActionError.notTheTrash) }
        let folder = open(trash.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else {
            let code = errno
            return (false, code == ELOOP || code == ENOTDIR ? TrashActionError.notTheTrash : removalError(code, path: trash.path))
        }
        defer { close(folder) }
        guard let opened = FolderIdentity(of: folder), opened == FolderIdentity(identity) else {
            return (false, TrashActionError.notTheTrash)
        }
        let names: [[CChar]]
        switch walk.listEntries(folder) {
        case .success(let found): names = found
        case .failure(let failure): return (false, removalError(failure.code, path: trash.path))
        }
        var deletion = Deletion()
        for name in names {
            // Still the same real folder at the Trash's path, never a link swapped in.
            guard let current = realFolderIdentity(trash), current == identity else {
                return (deletion.deletedSomething, TrashActionError.notTheTrash)
            }
            remove(name, inTrash: folder, identity: opened, path: trash.path + "/" + displayName(name), walk: walk, &deletion)
        }
        return (deletion.deletedSomething, deletion.error)
    }

    /// A folder's device and inode.
    nonisolated struct FolderIdentity: Equatable, Sendable {
        let device: dev_t, inode: ino_t

        init(_ identity: (dev_t, ino_t)) { (device, inode) = identity }

        init?(of descriptor: Int32) {
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
            (device, inode) = (info.st_dev, info.st_ino)
        }

        /// The folder at `child`, relative to the open folder; a final link isn't followed.
        init?(of descriptor: Int32, child: UnsafePointer<CChar>) {
            var info = stat()
            guard fstatat(descriptor, child, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
            (device, inode) = (info.st_dev, info.st_ino)
        }

        /// The identity of the open folder's parent (".."), or why it can't be read.
        static func parent(of descriptor: Int32) -> Result<FolderIdentity, SystemCallError> {
            var info = stat()
            guard fstatat(descriptor, "..", &info, AT_SYMLINK_NOFOLLOW) == 0 else { return .failure(SystemCallError(code: errno)) }
            guard info.st_mode & S_IFMT == S_IFDIR else { return .failure(SystemCallError(code: ENOTDIR)) }
            return .success(FolderIdentity((info.st_dev, info.st_ino)))
        }
    }

    /// The calls Empty Trash's walk makes besides deleting: listing an open folder and reading
    /// its parent's identity.
    nonisolated struct TrashWalk: Sendable {
        var listEntries: @Sendable (_ folder: Int32) -> Result<[[CChar]], SystemCallError>
        var parentOf: @Sendable (_ folder: Int32) -> Result<FolderIdentity, SystemCallError>

        static let system = TrashWalk(listEntries: TrashActions.entryNames(of:), parentOf: FolderIdentity.parent(of:))
    }

    /// Deletes the Trash's top-level entry `name`; a folder's contents first. Links are deleted,
    /// never followed. Walks with an explicit stack and keeps only the folder it works in open,
    /// going down by name and back up through "..", each checked to be the expected folder.
    /// Before every deletion the folder must still be in its parent: one moved meanwhile (out of
    /// the Trash, say) stops being emptied; a folder whose ancestor was moved, within 64 steps.
    /// A top-level folder renamed inside the Trash is still in it, so it keeps being emptied.
    private nonisolated static func remove(
        _ name: [CChar], inTrash trash: Int32, identity trashIdentity: FolderIdentity, path: String,
        walk: TrashWalk, _ deletion: inout Deletion
    ) {
        struct Folder {
            let identity: FolderIdentity, name: [CChar]
            let entries: [[CChar]]
            var next = 0
        }
        var chain: [Folder] = []        // from the top-level folder down to the one worked in
        var current: Int32 = -1         // the descriptor of chain.last
        var steps = 0                   // walk steps below the top-level folder, to space the ancestor checks
        defer { if current >= 0 { close(current) } }

        func parentIdentity(of index: Int) -> FolderIdentity { index == 0 ? trashIdentity : chain[index - 1].identity }
        // Built only for an error message: building it for every item would cost the depth.
        func pathOf(_ name: [CChar]?, depth: Int) -> String {
            ([path] + chain.prefix(depth).dropFirst().map { displayName($0.name) } + [name.map(displayName)].compactMap { $0 })
                .joined(separator: "/")
        }
        // Whether every folder above chain[index] is still in its recorded parent, up to the
        // Trash (chain[index]'s own parent is checked by the caller). Climbs one folder at a time
        // through ".." (never a link), so any depth is checked with two descriptors open.
        enum Ancestors { case inPlace, moved(Int), failed(Int32, Int) }
        func checkAncestors(of index: Int) -> Ancestors {
            var folder = current, owned = false
            defer { if owned { close(folder) } }
            for level in stride(from: index - 1, through: 0, by: -1) {
                let up = openat(folder, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                // It is open, so "gone" can't be taken as already deleted: report it.
                guard up >= 0 else { return .failed(errno == ENOENT ? EIO : errno, level + 1) }
                if owned { close(folder) }
                (folder, owned) = (up, true)
                // chain[level + 1]'s parent isn't chain[level]: it was moved.
                guard FolderIdentity(of: folder) == chain[level].identity else { return .moved(level + 1) }
                switch walk.parentOf(folder) {
                case .failure(let failure): return .failed(failure.code == ENOENT ? EIO : failure.code, level)
                case .success(let found) where found != parentIdentity(of: level): return .moved(level)
                case .success: continue
                }
            }
            return .inPlace
        }
        // Stops emptying this entry when an ancestor moved or can't be read; whether it stopped.
        func stopUnlessInPlace(_ ancestors: Ancestors) -> Bool {
            switch ancestors {
            case .inPlace: return false
            case .moved(let index): stopMoved(index)
            case .failed(let code, let index):
                deletion.fail(code, path: pathOf(nil, depth: index + 1))
                chain.removeAll()
            }
            return true
        }
        // Stops emptying this entry: chain[index] (the folder worked in by default) was moved.
        func stopMoved(_ index: Int? = nil) {
            let moved = index.map { chain[$0].name } ?? chain.last?.name ?? name
            deletion.error = deletion.error ?? TrashActionError.movedWhileEmptying(displayName(moved))
            chain.removeAll()
        }
        // Deletes anything but a folder at once; enters a folder so its entries go first.
        func visit(_ name: [CChar]) {
            let parent = current >= 0 ? current : trash
            let itemPath = { chain.isEmpty ? path : pathOf(name, depth: chain.count) }
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return deletion.fail(errno, path: itemPath()) }
            guard info.st_mode & S_IFMT == S_IFDIR else {
                if unlinkat(parent, name, 0) == 0 { deletion.deletedSomething = true } else { deletion.fail(errno, path: itemPath()) }
                return
            }
            let folder = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard folder >= 0 else { return deletion.fail(errno, path: itemPath()) }
            guard let identity = FolderIdentity(of: folder) else {
                close(folder)
                return deletion.fail(EIO, path: itemPath())
            }
            let entries: [[CChar]]
            switch walk.listEntries(folder) {
            case .success(let found): entries = found
            case .failure(let failure):
                entries = []
                deletion.fail(failure.code, path: itemPath())
            }
            // Its ".." must be readable to check, before every deletion, that it wasn't moved. If
            // it isn't (no search permission, say), don't enter it: an empty one can still go; a
            // full one stays, with that failure (for no permission, on its first entry, which is
            // what can't be reached).
            if case .failure(let failure) = walk.parentOf(folder) {
                close(folder)
                if let first = entries.first {
                    let path = failure.code == EACCES ? itemPath() + "/" + displayName(first) : itemPath()
                    // It is open, so "gone" can't be taken as already deleted: report it.
                    return deletion.fail(failure.code == ENOENT ? EIO : failure.code, path: path)
                }
                if unlinkat(parent, name, AT_REMOVEDIR) == 0 { deletion.deletedSomething = true } else { deletion.fail(errno, path: itemPath()) }
                return
            }
            if current >= 0 { close(current) }
            current = folder
            chain.append(Folder(identity: identity, name: name, entries: entries))
        }

        visit(name)
        while let last = chain.indices.last {
            // Still in the same parent: moving it out of the Trash changes its parent. A parent
            // that can't be read is reported as itself, never as a move.
            switch walk.parentOf(current) {
            case .failure(let failure):
                deletion.fail(failure.code == ENOENT ? EIO : failure.code, path: pathOf(nil, depth: last + 1))
                chain.removeAll()
                continue
            case .success(let found) where found != parentIdentity(of: last):
                stopMoved()
                continue
            case .success:
                break
            }
            // An ancestor moved out takes this folder along without changing its parent: check
            // the top-level folder before every deletion, and every ancestor every 64 steps
            // (an item deleted or a folder entered), so the climbs cost the depth once per 64.
            if last > 0 {
                var top = stat()
                if fstatat(trash, chain[0].name, &top, AT_SYMLINK_NOFOLLOW) != 0 {
                    let code = errno
                    if code != ENOENT {
                        // Can't be read: report that, not a move.
                        deletion.fail(code, path: path)
                        chain.removeAll()
                        continue
                    }
                    // Its name is gone: renamed in the Trash (or being deleted) is fine; climb
                    // to see whether it is still in the Trash.
                    if stopUnlessInPlace(checkAncestors(of: last)) { continue }
                } else if FolderIdentity(of: trash, child: chain[0].name) != chain[0].identity {
                    // Another item took its name: it was moved away.
                    stopMoved(0)
                    continue
                } else if steps % 64 == 0, stopUnlessInPlace(checkAncestors(of: last)) {
                    continue
                }
            }
            steps += 1
            if chain[last].next < chain[last].entries.count {
                let child = chain[last].entries[chain[last].next]
                chain[last].next += 1
                visit(child)
                continue
            }
            // Done with its entries: go back up to its parent and delete it there.
            let parent: Int32
            if last == 0 {
                parent = trash
            } else {
                parent = openat(current, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                guard parent >= 0, FolderIdentity(of: parent) == chain[last - 1].identity else {
                    if parent >= 0 { close(parent) }
                    stopMoved()
                    continue
                }
            }
            close(current)
            current = last == 0 ? -1 : parent
            if unlinkat(parent, chain[last].name, AT_REMOVEDIR) == 0 {
                deletion.deletedSomething = true
            } else {
                let code = errno
                // Not empty because something inside couldn't go: that failure is already recorded.
                if code != ENOTEMPTY || deletion.error == nil { deletion.fail(code, path: pathOf(nil, depth: last + 1)) }
            }
            chain.removeLast()
        }
    }

    /// The raw names in an open folder (raw, so any name still matches), or the error that
    /// stopped the listing: a read error never passes for the end of the folder.
    nonisolated static func entryNames(of folder: Int32) -> Result<[[CChar]], SystemCallError> {
        let copy = dup(folder)
        guard copy >= 0 else { return .failure(SystemCallError(code: errno)) }
        guard let directory = fdopendir(copy) else {
            let code = errno
            close(copy)
            return .failure(SystemCallError(code: code))
        }
        defer { closedir(directory) }
        var names: [[CChar]] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                let code = errno
                return code == 0 ? .success(names) : .failure(SystemCallError(code: code))
            }
            let length = Int(entry.pointee.d_namlen)
            var name = withUnsafeBytes(of: entry.pointee.d_name) { Array($0.bindMemory(to: CChar.self).prefix(length)) }
            if name == [46] || name == [46, 46] { continue }   // "." and ".."
            name.append(0)
            names.append(name)
        }
    }

    /// A failed system call's error code.
    nonisolated struct SystemCallError: Error, Sendable { let code: Int32 }

    private nonisolated static func displayName(_ name: [CChar]) -> String {
        String(decoding: name.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Like `FileManager.removeItem`'s errors: "“name” couldn't be removed because…".
    private nonisolated static func removalError(_ code: Int32, path: String) -> any Error {
        let kind: CocoaError.Code = code == EPERM || code == EACCES ? .fileWriteNoPermission : .fileWriteUnknown
        return CocoaError(kind, userInfo: [
            NSFilePathErrorKey: path,
            "NSUserStringVariant": ["Remove"],
            NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) as NSError,
        ])
    }


    // MARK: - Undo registration

    /// Whether undoing a step needs the Trash (its items went there, `undo`) and whether redoing
    /// it does (they came from there, `redo`): emptying the Trash breaks those steps.
    nonisolated struct TrashNeeds: Sendable {
        var undo = false, redo = false
    }

    /// The Trash needs of `transfers` (a trip into the Trash, a move out, a rename in it), worked
    /// out off the main actor: it reads each folder above an item, which can be slow on a
    /// network volume.
    @concurrent nonisolated static func trashNeeds(_ transfers: [FileTransfer], trash: URL) async -> TrashNeeds {
        TrashNeeds(
            undo: transfers.contains { isInTrash($0.to, trash: trash) },
            redo: transfers.contains { isInTrash($0.from, trash: trash) })
    }

    /// `done` already happened; undoing it moves those items back.
    private func registerRelocationUndo(_ actionName: String, _ done: [FileTransfer], needsTrash: TrashNeeds) {
        registerRelocationUndo(actionName, RelocationRecord(transfers: done), needsTrash: needsTrash)
    }

    /// Whether `url` is inside `trash`, the Trash that Empty Trash empties; another folder named
    /// ".Trash" or another volume's `.Trashes` isn't emptied, so its steps keep working. Compared
    /// by folder identity, so a path spelled through a link or in other letter case counts too.
    nonisolated static func isInTrash(_ url: URL, trash trashFolder: URL) -> Bool {
        if url.canonical.path.hasPrefix(trashFolder.path + "/") { return true }
        var trash = stat()
        guard stat(trashFolder.path, &trash) == 0 else { return false }
        // The parent with its links resolved, then each of its folders up to the root.
        var folder = url.deletingLastPathComponent().resolvingSymlinksInPath()
        while true {
            var info = stat()
            if stat(folder.path, &info) == 0, info.st_dev == trash.st_dev, info.st_ino == trash.st_ino { return true }
            if folder.pathComponents.count <= 1 { return false }   // the root
            folder = folder.deletingLastPathComponent()
        }
    }

    /// Undo and redo hand each other a record of what their disk work really moved, so a step
    /// that stopped partway is reversed only as far as it got. `needsTrash.undo` says whether
    /// this entry moves items out of the Trash (emptying it breaks the entry, see
    /// `dropTrashUndo`); `needsTrash.redo`, the same for the entry it registers in turn.
    private func registerRelocationUndo(
        _ actionName: String, _ record: RelocationRecord, needsTrash: TrashNeeds
    ) {
        registerUndo(actionName, target: needsTrash.undo ? trashUndoTarget : self) { actions in
            let reverse = RelocationRecord(transfers: [])
            actions.registerRelocationUndo(actionName, reverse, needsTrash: TrashNeeds(undo: needsTrash.redo, redo: needsTrash.undo))
            actions.enqueue {
                // Read the record when the work runs: the step before it has finished by then.
                let plan = record.transfers.reversed().map(\.reversed)
                let result = await Self.performMoves(plan, stopOnError: false)
                reverse.transfers = result.done
                return result
            }
        }
    }


    private func registerUndo(
        _ actionName: String, target: AnyObject? = nil, _ handler: @escaping (TrashActions) -> Void
    ) {
        guard let undoManager else { return }
        // Registrations made while undoing/redoing are grouped by the undo manager itself.
        let needsGroup = !undoManager.isUndoing && !undoManager.isRedoing
        if needsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: target ?? self) { [weak self] _ in
            if let self { handler(self) }
        }
        undoManager.setActionName(actionName)
        if needsGroup { undoManager.endUndoGrouping() }
    }

    /// Runs `operation` after everything already queued, and returns its result.
    private func serialized(_ operation: @escaping () async throws -> Void) async throws {
        let previous = lastWork
        queuedOperations += 1
        let task = Task<Void, any Error> {
            await previous?.value
            self.queuedOperations -= 1
            try await operation()
        }
        lastWork = Task { _ = try? await task.value }
        return try await task.value
    }

    /// Queues undo/redo work, which has no caller, and reports its failure.
    private func enqueue(_ work: @escaping () async -> BatchResult) {
        let previous = lastWork
        lastWork = Task {
            await previous?.value
            let result = await work()
            if let error = result.error { report(error) }
        }
    }

    private func report(_ error: any Error) {
        onBackgroundError?(error.localizedDescription)
    }

    // MARK: - Disk work (off the main actor)

    /// Moves each item back where it came from; goes on past failures when `stopOnError` is off.
    @concurrent private nonisolated static func performMoves(_ plan: [FileTransfer], stopOnError: Bool = true) async -> BatchResult {
        var result = BatchResult()
        for transfer in plan {
            do {
                try FileManager.default.moveItem(at: transfer.from, to: transfer.to)
                result.done.append(transfer)
            } catch {
                result.error = error
                if stopOnError { break }
            }
        }
        return result
    }

    @concurrent private nonisolated static func performTrash(_ urls: [URL], trasher: Trasher) async -> BatchResult {
        var result = BatchResult()
        for url in urls {
            do {
                if let trashed = try trasher(url) { result.done.append(FileTransfer(from: url, to: trashed)) }
            } catch {
                result.error = error
                break
            }
        }
        return result
    }

    nonisolated static func uniqueDestination(
        for source: URL, in folder: URL, copyStyle: Bool, reserved: Set<String> = []
    ) -> URL {
        let fileManager = FileManager.default
        func isFree(_ url: URL) -> Bool {
            !reserved.contains(url.lastPathComponent.lowercased()) && !fileManager.fileExists(atPath: url.path)
        }
        let name = source.lastPathComponent
        let candidate = folder.appendingPathComponent(name)
        if !copyStyle, isFree(candidate) { return candidate }

        let ext = source.pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var index = copyStyle ? 1 : 2
        while true {
            let stem = copyStyle
                ? (index == 1 ? "\(base) copy" : "\(base) copy \(index)")
                : "\(base) \(index)"
            let url = folder.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
            if isFree(url) { return url }
            index += 1
        }
    }
}
