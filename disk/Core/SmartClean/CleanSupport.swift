import Foundation

extension URL {
    /// File URL without a trailing slash, so the same path always compares equal
    /// (`contentsOfDirectory` appends "/" to folders, `appendingPathComponent` may not).
    nonisolated var canonical: URL {
        URL(filePath: standardizedFileURL.path, directoryHint: .notDirectory)
    }
}

extension Int64 {
    /// "1.2 GB", the way Finder shows sizes.
    nonisolated var fileSizeText: String { formatted(.byteCount(style: .file)) }
}

nonisolated struct FolderStats: Equatable, Sendable {
    /// Sum of the logical sizes of every file below the folder, hidden files included.
    var totalBytes: Int64
    /// Number of visible direct children, as Finder reports "12 items".
    var itemCount: Int
}

/// Walks a folder tree to compute its size. Synchronous: call it off the main actor.
nonisolated enum FolderSizeCalculator {
    static func measure(_ folder: URL) throws -> FolderStats {
        let visibleChildren = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

        var totalBytes: Int64 = 0
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { _, _ in true })
        while let url = enumerator?.nextObject() as? URL {
            if Task.isCancelled { throw CancellationError() }
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            totalBytes += Int64(values.fileSize ?? 0)
        }
        return FolderStats(totalBytes: totalBytes, itemCount: visibleChildren.count)
    }
}
