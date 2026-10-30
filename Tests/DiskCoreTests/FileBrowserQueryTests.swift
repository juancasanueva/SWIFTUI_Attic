import Foundation
import Testing
@testable import DiskCore

@Suite struct FileBrowserQueryTests {
    private func names(_ query: FileBrowserQuery, _ tree: FileTree, focus: NodeID = FileTree.rootID) throws -> [String] {
        try query.results(in: tree, focus: focus).map { tree[$0].name }
    }

    @Test func noCriteriaListsTheFocusedFolderLargestFirst() throws {
        #expect(try names(FileBrowserQuery(), sampleTree()) == ["a", "b.app", "c.bin"])
    }

    @Test func textSearchesAllDescendantsOfTheFocus() throws {
        let tree = sampleTree()
        var query = FileBrowserQuery()
        query.text = "BIN"
        #expect(try names(query, tree) == ["x.bin", "c.bin"])
        #expect(try names(query, tree, focus: tree.id("a")) == ["x.bin"])
    }

    @Test func entireScanScopeIgnoresTheFocus() throws {
        let tree = sampleTree()
        var query = FileBrowserQuery()
        query.text = "c.bin"
        query.scope = .entireScan
        #expect(try names(query, tree, focus: tree.id("a")) == ["c.bin"])
    }

    @Test func kindFilterSearchesTheFocusForMatchingItems() throws {
        var query = FileBrowserQuery()
        query.kinds = [.package]
        #expect(try names(query, sampleTree()) == ["b.app"])
        query.kinds = [.folder]
        #expect(try names(query, sampleTree()) == ["a"])
        query.kinds = [.file]
        #expect(try names(query, sampleTree()) == ["x.bin", "z", "y.txt", "c.bin"])
    }

    @Test func sizeFilterUsesAllocatedSizeAcrossTheFocus() throws {
        var query = FileBrowserQuery()
        query.minimumSize = 350
        #expect(try names(query, sampleTree()) == ["a", "x.bin"])
    }

    @Test(arguments: [
        (FileBrowserQuery.SortField.name, true, ["a", "b.app", "c.bin"]),
        (.name, false, ["c.bin", "b.app", "a"]),
        (.allocatedSize, true, ["c.bin", "b.app", "a"]),
        (.fileCount, false, ["a", "b.app", "c.bin"]),
    ])
    func sortsByField(field: FileBrowserQuery.SortField, ascending: Bool, expected: [String]) throws {
        var query = FileBrowserQuery()
        query.sortField = field
        query.ascending = ascending
        #expect(try names(query, sampleTree()) == expected)
    }

    @Test func removedItemsAreNotFound() throws {
        let tree = sampleTree()
        let updated = tree.removing([tree.id("a")])
        var query = FileBrowserQuery()
        query.text = "x.bin"
        #expect(try names(query, updated).isEmpty)
    }

    @Test func cancelledSearchThrows() async {
        let tree = sampleTree()
        var query = FileBrowserQuery()
        query.text = "x"
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try query.results(in: tree, focus: FileTree.rootID)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}
