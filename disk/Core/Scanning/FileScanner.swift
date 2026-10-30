import Foundation

nonisolated struct ScanProgress: Sendable, Equatable {
    var filesScanned = 0
    var foldersScanned = 0
    var allocatedBytes: Int64 = 0
    var warnings = 0
    var currentPath = ""
}

/// Which directories a scan may enter. A folder on another device is listed but not
/// descended into, so network shares and external disks never inflate a scan.
nonisolated struct VolumeBoundary: Sendable {
    let allowedDevices: Set<Int32>
    let excludedPaths: Set<String>

    func allows(path: String, device: Int32) -> Bool {
        allowedDevices.contains(device) && !excludedPaths.contains(path)
    }

    /// On the startup disk `/Users` and friends are firmlinks into the Data volume, which
    /// has its own device. The Data volume is allowed, and the places that would expose
    /// the same content a second time are excluded.
    static func forRoot(path: String, device: Int32, dataVolumeDevice: Int32?) -> VolumeBoundary {
        guard path == "/" else { return VolumeBoundary(allowedDevices: [device], excludedPaths: []) }
        return VolumeBoundary(
            allowedDevices: Set([device, dataVolumeDevice].compactMap(\.self)),
            excludedPaths: ["/System/Volumes", "/Volumes", "/dev"])
    }
}

nonisolated struct FileScanner: Sendable {
    enum Failure: Error, Equatable {
        case cannotRead(path: String, reason: String)
    }

    @concurrent
    func scan(root: URL, onProgress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) async throws -> FileTree {
        let path = root.path
        var rootInfo = stat()
        guard stat(path, &rootInfo) == 0 else {
            throw Failure.cannotRead(path: path, reason: String(cString: strerror(errno)))
        }
        guard rootInfo.st_mode & S_IFMT == S_IFDIR else {
            throw Failure.cannotRead(path: path, reason: "Not a folder")
        }

        var dataInfo = stat()
        let dataDevice = stat("/System/Volumes/Data", &dataInfo) == 0 ? dataInfo.st_dev : nil
        let boundary = VolumeBoundary.forRoot(path: path, device: rootInfo.st_dev, dataVolumeDevice: dataDevice)
        let rootDirectory = RawDirectory(
            name: Self.displayName(of: root), modified: TimeInterval(rootInfo.st_mtimespec.tv_sec))
        let run = ScanRun(root: rootDirectory, path: path, boundary: boundary, onProgress: onProgress)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let workers = min(ProcessInfo.processInfo.activeProcessorCount, 8)
                    DispatchQueue.concurrentPerform(iterations: workers) { _ in run.work() }
                    guard !run.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    run.reportFinalProgress()
                    continuation.resume(returning: FileTree(
                        rootPath: path, rootDirectory: rootDirectory, warnings: run.warnings))
                }
            }
        } onCancel: {
            run.cancel()
        }
    }

    private static func displayName(of url: URL) -> String {
        guard url.path == "/" else { return url.lastPathComponent }
        return (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "/"
    }
}

// MARK: - Shared scan state

/// Work queue and counters shared by the scanner workers. Each `RawDirectory` is touched
/// by one worker only, so the lock guards the queue and the counters, never the tree.
private nonisolated final class ScanRun: @unchecked Sendable {
    private typealias WorkItem = (directory: RawDirectory, path: String)
    private struct HardLink: Hashable {
        let device: Int32
        let fileID: UInt64
    }

    private let boundary: VolumeBoundary
    private let onProgress: @Sendable (ScanProgress) -> Void
    private let condition = NSCondition()
    private let hardLinkLock = NSLock()
    private var seenHardLinks = Set<HardLink>()
    private var pending: [WorkItem]
    private var inFlight = 0
    private var cancelled = false
    private var progress = ScanProgress()
    private var lastReport = ContinuousClock.now
    private(set) var warnings: [ScanWarning] = []

    init(root: RawDirectory, path: String, boundary: VolumeBoundary, onProgress: @escaping @Sendable (ScanProgress) -> Void) {
        pending = [(root, path)]
        self.boundary = boundary
        self.onProgress = onProgress
    }

    var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    func cancel() {
        condition.lock()
        cancelled = true
        pending.removeAll()
        condition.broadcast()
        condition.unlock()
    }

    func reportFinalProgress() { onProgress(progress) }

    func work() {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 256 * 1024, alignment: 8)
        defer { buffer.deallocate() }
        while let item = next() {
            finish(item, read(item, into: buffer))
        }
    }

    private func next() -> WorkItem? {
        condition.lock()
        defer { condition.unlock() }
        while pending.isEmpty {
            if inFlight == 0 || cancelled { return nil }
            condition.wait()
        }
        inFlight += 1
        return pending.removeLast()
    }

    private struct Batch {
        var discovered: [WorkItem] = []
        var files = 0
        var bytes: Int64 = 0
        var warning: ScanWarning?
    }

    private func finish(_ item: WorkItem, _ batch: Batch) {
        condition.lock()
        inFlight -= 1
        if !cancelled { pending.append(contentsOf: batch.discovered) }
        progress.filesScanned += batch.files
        progress.foldersScanned += 1
        progress.allocatedBytes += batch.bytes
        progress.currentPath = item.path
        if let warning = batch.warning {
            warnings.append(warning)
            progress.warnings += 1
        }
        var report: ScanProgress?
        let now = ContinuousClock.now
        if now - lastReport > .milliseconds(100) {
            lastReport = now
            report = progress
        }
        condition.broadcast()
        condition.unlock()
        if let report { onProgress(report) }
    }

    private func isFirstSighting(device: Int32, fileID: UInt64) -> Bool {
        hardLinkLock.lock()
        defer { hardLinkLock.unlock() }
        return seenHardLinks.insert(HardLink(device: device, fileID: fileID)).inserted
    }

    // MARK: Directory reading

    private func read(_ item: WorkItem, into buffer: UnsafeMutableRawBufferPointer) -> Batch {
        var batch = Batch()
        let descriptor = open(item.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            markUnreadable(item, &batch)
            return batch
        }
        defer { close(descriptor) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FILEID)
        request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_TOTALSIZE)
            | attrgroup_t(ATTR_FILE_ALLOCSIZE)

        while !isCancelled {
            let count = getattrlistbulk(descriptor, &request, buffer.baseAddress!, buffer.count, 0)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                markUnreadable(item, &batch)
                break
            }
            var cursor = UnsafeRawPointer(buffer.baseAddress!)
            for _ in 0..<count {
                let length = cursor.loadUnaligned(as: UInt32.self)
                consume(Self.parseEntry(cursor), of: item, &batch)
                cursor += Int(length)
            }
        }
        return batch
    }

    private func markUnreadable(_ item: WorkItem, _ batch: inout Batch) {
        item.directory.isUnreadable = true
        batch.warning = ScanWarning(path: item.path, message: String(cString: strerror(errno)))
    }

    private func consume(_ entry: ParsedEntry, of item: WorkItem, _ batch: inout Batch) {
        guard entry.objectType == VDIR.rawValue else {
            var allocated = entry.allocatedSize
            if entry.linkCount > 1, !isFirstSighting(device: entry.device, fileID: entry.fileID) {
                allocated = 0
            }
            item.directory.entries.append(RawDirectory.Entry(
                name: entry.name,
                kind: entry.objectType == VREG.rawValue ? .file : entry.objectType == VLNK.rawValue ? .symlink : .other,
                allocatedSize: allocated, logicalSize: entry.logicalSize, modified: entry.modified))
            batch.files += 1
            batch.bytes += allocated
            return
        }

        let child = RawDirectory(
            name: entry.name, kind: PackageClassifier.kind(ofFolderNamed: entry.name), modified: entry.modified)
        item.directory.subdirectories.append(child)
        let childPath = item.path == "/" ? "/" + entry.name : item.path + "/" + entry.name
        if boundary.allows(path: childPath, device: entry.device) {
            batch.discovered.append((child, childPath))
        }
    }

    private struct ParsedEntry {
        var name = ""
        var device: Int32 = 0
        var objectType: UInt32 = 0
        var modified: TimeInterval = 0
        var fileID: UInt64 = 0
        var linkCount: UInt32 = 1
        var logicalSize: Int64 = 0
        var allocatedSize: Int64 = 0
    }

    /// Decodes one `getattrlistbulk` record. Values are packed in attribute bit order, and
    /// only the attributes listed in `returned` are present. See getattrlistbulk(2).
    private static func parseEntry(_ start: UnsafeRawPointer) -> ParsedEntry {
        var entry = ParsedEntry()
        var field = start + MemoryLayout<UInt32>.size
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += MemoryLayout<attribute_set_t>.size

        func has(_ mask: Int32, in group: attrgroup_t) -> Bool { group & attrgroup_t(mask) != 0 }
        func take<T: BitwiseCopyable>(_ type: T.Type) -> T {
            defer { field += MemoryLayout<T>.size }
            return field.loadUnaligned(as: T.self)
        }

        if has(ATTR_CMN_ERROR, in: returned.commonattr) { _ = take(UInt32.self) }
        if has(ATTR_CMN_NAME, in: returned.commonattr) {
            let reference = field.loadUnaligned(as: attrreference_t.self)
            entry.name = String(cString: (field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
            field += MemoryLayout<attrreference_t>.size
        }
        if has(ATTR_CMN_DEVID, in: returned.commonattr) { entry.device = take(Int32.self) }
        if has(ATTR_CMN_OBJTYPE, in: returned.commonattr) { entry.objectType = take(UInt32.self) }
        if has(ATTR_CMN_MODTIME, in: returned.commonattr) { entry.modified = TimeInterval(take(timespec.self).tv_sec) }
        if has(ATTR_CMN_FILEID, in: returned.commonattr) { entry.fileID = take(UInt64.self) }
        if has(ATTR_FILE_LINKCOUNT, in: returned.fileattr) { entry.linkCount = take(UInt32.self) }
        if has(ATTR_FILE_TOTALSIZE, in: returned.fileattr) { entry.logicalSize = take(Int64.self) }
        if has(ATTR_FILE_ALLOCSIZE, in: returned.fileattr) { entry.allocatedSize = take(Int64.self) }
        return entry
    }
}

nonisolated enum PackageClassifier {
    private static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "kext", "plugin", "xcodeproj", "xcworkspace", "xcarchive",
        "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "playground",
        "pages", "numbers", "key", "rtfd", "sparsebundle", "dSYM",
    ]

    static func kind(ofFolderNamed name: String) -> NodeKind {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return .folder }
        return packageExtensions.contains(String(name[name.index(after: dot)...])) ? .package : .folder
    }
}
