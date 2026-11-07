import Foundation

/// A throwaway directory under the system temp dir, removed on deinit.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func file(_ relativePath: String, bytes: Int = 0) throws -> URL {
        let fileURL = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: fileURL)
        return fileURL
    }

    @discardableResult
    func folder(_ relativePath: String) throws -> URL {
        let folderURL = url.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return folderURL
    }
}
