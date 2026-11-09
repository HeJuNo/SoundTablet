import Foundation
import Testing
@testable import SoundTablet

@Suite struct BoardStoreTests {
    func makeStore() throws -> (LocalBoardStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (LocalBoardStore(root: root), root)
    }
    func board(_ name: String) -> Board { Board(id: UUID(), name: name, colorHex: "#FF0000") }

    @Test func saveThenLoad() async throws {
        let (store, _) = try makeStore()
        let b = board("Show")
        try await store.save(b)
        #expect(try await store.loadBoards() == [b])
    }

    @Test func importCopiesFile() async throws {
        let (store, root) = try makeStore()
        let b = board("Show"); try await store.save(b)
        let src = root.appendingPathComponent("src.wav"); try Data([1, 2, 3]).write(to: src)
        let tid = UUID()
        let name = try await store.importAudio(from: src, into: b.id, as: tid)
        let url = try #require(try await store.audioURL(board: b.id, fileName: name))
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
    }

    @Test func missingAudioReturnsNil() async throws {
        let (store, _) = try makeStore()
        let b = board("Show"); try await store.save(b)
        #expect(try await store.audioURL(board: b.id, fileName: "nope.wav") == nil)
    }

    @Test func duplicateNamesDoNotOverwrite() async throws {
        let (store, root) = try makeStore()
        try await store.save(board("A")); try await store.save(board("A"))
        #expect(try await store.loadBoards().count == 2)
        let dirs = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(dirs == ["A", "A 2"])
    }

    @Test func sanitizesSlashAndColon() {
        #expect(sanitizedFolderName("a/b:c") == "abc")
        #expect(sanitizedFolderName("  ") == "Untitled")
        #expect(sanitizedFolderName("..hidden") == "hidden")
    }
}
