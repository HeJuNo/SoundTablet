import Foundation
import Testing
@testable import SoundTablet

@Suite struct SyncServiceTests {
    let local: URL, cloud: URL
    let fm = FileManager.default
    init() throws {
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        local = base.appendingPathComponent("local"); cloud = base.appendingPathComponent("cloud")
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        try fm.createDirectory(at: cloud, withIntermediateDirectories: true)
    }
    func write(_ root: URL, _ path: String, _ text: String, mtime: Double) throws {
        let u = root.appendingPathComponent(path)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: u.path)
    }
    func read(_ root: URL, _ path: String) -> String? { try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
    func sync() throws -> SyncReport { try SyncService(local: local, cloud: cloud).sync() }

    @Test func newFileOnEitherSideIsCopied() throws {
        try write(local, "A/board.json", "L", mtime: 1000)
        try write(cloud, "B/board.json", "C", mtime: 1000)
        let r = try sync()
        #expect(read(cloud, "A/board.json") == "L" && read(local, "B/board.json") == "C")
        #expect(r.copiedToCloud == 1 && r.copiedToLocal == 1 && r.conflicts.isEmpty)
    }

    @Test func newerLocalFileOverwritesCloud() throws {
        try write(local, "a.txt", "v1", mtime: 1000); _ = try sync()
        try write(local, "a.txt", "v2", mtime: 2000)
        let r = try sync()
        #expect(read(cloud, "a.txt") == "v2" && r.copiedToCloud == 1 && r.copiedToLocal == 0)
    }

    @Test func newerCloudFileOverwritesLocal() throws {
        try write(local, "a.txt", "v1", mtime: 1000); _ = try sync()
        try write(cloud, "a.txt", "v2", mtime: 2000)
        let r = try sync()
        #expect(read(local, "a.txt") == "v2" && r.copiedToLocal == 1 && r.copiedToCloud == 0)
    }

    @Test func bothChangedKeepsLoserAsKonfliktCopy() throws {
        try write(local, "d/a.txt", "v1", mtime: 1000); _ = try sync()
        try write(local, "d/a.txt", "local edit", mtime: 2000)
        try write(cloud, "d/a.txt", "cloud edit", mtime: 3000)
        let r = try sync()
        #expect(read(local, "d/a.txt") == "cloud edit" && read(cloud, "d/a.txt") == "cloud edit")
        #expect(r.conflicts == ["d/a.txt"])
        let copies = try fm.contentsOfDirectory(atPath: local.appendingPathComponent("d").path).filter { $0.contains("Konflikt") }
        #expect(copies.count == 1)
        #expect(read(local, "d/" + copies[0]) == "local edit")
    }

    @Test func deletionOnOneSidePropagates() throws {
        try write(local, "A/board.json", "v1", mtime: 1000); try write(local, "A/x.wav", "v1", mtime: 1000)
        try write(local, "B/board.json", "v1", mtime: 1000); _ = try sync()
        try fm.removeItem(at: local.appendingPathComponent("A"))           // board deleted on this device
        try fm.removeItem(at: cloud.appendingPathComponent("B/board.json")) // board deleted on another device
        let r = try sync()
        #expect(read(cloud, "A/board.json") == nil && read(cloud, "A/x.wav") == nil)
        #expect(read(local, "B/board.json") == nil)
        #expect(!fm.fileExists(atPath: cloud.appendingPathComponent("A").path))   // no empty folder left behind
        #expect(r.removed == 3)
        #expect(try sync() == SyncReport())
    }

    @Test func deletedBoardFolderIsRemovedFromCloudEvenIfItsFilesLookChanged() throws {
        try write(local, "A/board.json", "v1", mtime: 1000); try write(local, "A/x.wav", "v1", mtime: 1000); _ = try sync()
        try fm.removeItem(at: local.appendingPathComponent("A"))
        SyncService.markDeleted("A", in: local)
        try write(cloud, "A/board.json", "v1", mtime: 5000)                // iCloud touched the file
        try write(cloud, "A/.x.wav.icloud", "placeholder", mtime: 1000)   // and evicted another one
        try fm.removeItem(at: cloud.appendingPathComponent("A/x.wav"))
        _ = try sync()
        #expect(!fm.fileExists(atPath: cloud.appendingPathComponent("A").path) && !fm.fileExists(atPath: local.appendingPathComponent("A").path))
        #expect(try sync() == SyncReport())
    }

    @Test func editBeatsDeletionOnTheOtherSide() throws {
        try write(local, "a.txt", "v1", mtime: 1000); try write(local, "b.txt", "v1", mtime: 1000); _ = try sync()
        try fm.removeItem(at: local.appendingPathComponent("a.txt"))
        try write(cloud, "a.txt", "edited", mtime: 2000)                   // changed elsewhere meanwhile
        try fm.removeItem(at: cloud.appendingPathComponent("b.txt"))
        try write(local, "b.txt", "edited", mtime: 2000)
        _ = try sync()
        #expect(read(local, "a.txt") == "edited" && read(cloud, "b.txt") == "edited")
    }

    @Test func notDownloadedFileIsNotTreatedAsDeleted() throws {
        try write(local, "a.wav", "v1", mtime: 1000); _ = try sync()
        try fm.removeItem(at: cloud.appendingPathComponent("a.wav"))
        try write(cloud, ".a.wav.icloud", "placeholder", mtime: 1000)     // iCloud evicted it, it is still there
        _ = try sync()
        #expect(read(local, "a.wav") == "v1")
    }

    @Test func onlyChangedSideWinsEvenWithOlderTimestamp() throws {
        try write(local, "board.json", "old", mtime: 5000); _ = try sync()
        try write(local, "board.json", "renamed", mtime: 4000)             // e.g. clock behind: still the only edit
        _ = try sync()
        #expect(read(cloud, "board.json") == "renamed")
    }

    @Test func secondSyncIsNoOp() throws {
        try write(local, "a.txt", "v1", mtime: 1000); try write(cloud, "b.txt", "v1", mtime: 1000)
        _ = try sync()
        #expect(try sync() == SyncReport())
    }

    /// Local a.txt is newer but unreadable (copy fails); b.txt is a new local file.
    func failingSetup() throws -> URL {
        try write(local, "a.txt", "v1", mtime: 1000); _ = try sync()
        try write(local, "a.txt", "v2", mtime: 2000)
        try write(local, "b.txt", "new", mtime: 2000)
        let a = local.appendingPathComponent("a.txt")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: a.path)
        return a
    }

    @Test func failedCopyKeepsDestinationIntact() throws {
        let a = try failingSetup()
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: a.path) }
        let r = try sync()
        #expect(r.errors == ["a.txt"])
        #expect(read(cloud, "a.txt") == "v1")   // old version still there, not removed or truncated
    }

    @Test func syncContinuesPastOneBadFile() throws {
        let a = try failingSetup()
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: a.path) }
        let r = try sync()
        #expect(read(cloud, "b.txt") == "new" && r.copiedToCloud == 1)
        // after the file becomes readable again, the next sync recovers
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: a.path)
        let r2 = try sync()
        #expect(r2.errors.isEmpty && read(cloud, "a.txt") == "v2")
    }
}
