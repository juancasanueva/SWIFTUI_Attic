import CryptoKit
import Darwin
import Foundation

/// Finds files with identical contents in the user folders. In each set of copies the one
/// opened last is kept (then the one modified last, the shortest path, alphabetical order);
/// every other copy is a candidate. Hard links to one file are never duplicates of each other.
nonisolated struct DuplicatesScanner: SuggestionScanner {
    let kind = SuggestionKind.duplicates
    let minimumSize: Int64

    /// Bytes compared before hashing whole files.
    private static let headLength = 64 * 1024
    private static let chunkLength = 1024 * 1024

    init(minimumSize: Int64 = 1_000_000) {
        self.minimumSize = minimumSize
    }

    func scan(_ environment: CleanEnvironment) async throws -> [CleanCandidate] {
        let roots = environment.userFolders.filter { FileManager.default.fileExists(atPath: $0.path) }
        var bySize: [Int64: [URL]] = [:]
        try CleanWalker.regularFiles(in: roots, minimumSize: minimumSize) { url, size in
            bySize[size, default: []].append(url)
        }

        var candidates: [CleanCandidate] = []
        for (size, urls) in bySize where urls.count > 1 {
            let files = Self.distinctPhysicalFiles(urls)
            guard files.count > 1 else { continue }
            for sameHead in try Self.grouped(files, by: { try Self.hash($0, limit: Self.headLength) }) {
                for copies in try Self.grouped(sameHead, by: { try Self.hash($0, limit: nil) }) {
                    let kept = Self.keptCopy(of: copies, environment: environment)
                    let detail = "Copy of \(Self.displayPath(kept, home: environment.home))"
                    for copy in copies where copy != kept {
                        candidates.append(CleanCandidate(url: copy, bytes: size, detail: detail, keptCopy: kept))
                    }
                }
            }
        }
        return candidates.sorted { $0.url.path < $1.url.path }
    }

    /// Drops every file that shares its physical identity (hard links) with another one.
    private static func distinctPhysicalFiles(_ urls: [URL]) -> [URL] {
        var byIdentity: [String: [URL]] = [:]
        var unidentified: [URL] = []
        for url in Set(urls) {
            if let identity = physicalIdentity(url) {
                byIdentity[identity, default: []].append(url)
            } else {
                unidentified.append(url)
            }
        }
        return byIdentity.values.filter { $0.count == 1 }.flatMap { $0 } + unidentified
    }

    /// Device and inode, which hard links share.
    private static func physicalIdentity(_ url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }

    /// Groups of two or more files with the same key; files whose key can't be read are skipped.
    private static func grouped(_ urls: [URL], by key: (URL) throws -> Data?) throws -> [[URL]] {
        var groups: [Data: [URL]] = [:]
        for url in urls {
            try Task.checkCancellation()
            guard let value = try key(url) else { continue }
            groups[value, default: []].append(url)
        }
        return groups.values.filter { $0.count > 1 }
    }

    /// SHA-256 of the first `limit` bytes (all of them when `nil`), read in chunks; `nil` when unreadable.
    private static func hash(_ url: URL, limit: Int?) throws -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            try Task.checkCancellation()
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: min(chunkLength, remaining))
            } catch {
                return nil
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return Data(hasher.finalize())
    }

    /// The copy opened last, then modified last, then the shortest path, then alphabetical.
    private static func keptCopy(of copies: [URL], environment: CleanEnvironment) -> URL {
        let ranked = copies.map { url in
            (url: url,
             opened: environment.lastOpened(url) ?? .distantPast,
             modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                 .contentModificationDate ?? .distantPast)
        }
        let best = ranked.min { lhs, rhs in
            if lhs.opened != rhs.opened { return lhs.opened > rhs.opened }
            if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
            if lhs.url.path.count != rhs.url.path.count { return lhs.url.path.count < rhs.url.path.count }
            return lhs.url.path < rhs.url.path
        }
        return best!.url
    }

    /// The path with the home folder shown as "~".
    private static func displayPath(_ url: URL, home: URL) -> String {
        let path = url.canonical.path
        for homePath in Set([home.canonical.path, home.resolvingSymlinksInPath().canonical.path]) {
            if path == homePath { return "~" }
            if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        }
        return path
    }
}
