import Foundation
import Testing
import UIKit
@testable import SoundTablet

@MainActor @Suite struct AppModelTests {
    func makeModel(store: LocalBoardStore? = nil) throws -> (AppModel, LocalBoardStore) {
        let s = try store ?? LocalBoardStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        return (AppModel(store: s, manualRendering: true), s)
    }

    @Test func importCreatesTracksWithDefaults() async throws {
        let (m, store) = try makeModel()
        await m.addBoard(name: "Show")
        await m.importTracks([try makeTone()])
        let t = try #require(m.boards.first?.tracks.first)
        #expect(t.settings == .default)
        #expect(try await store.audioURL(board: m.boards[0].id, fileName: t.fileName) != nil)
        #expect(m.unavailable.isEmpty)
    }

    @Test func tapPlaysAndAutomationFires() async throws {
        let (m, _) = try makeModel()
        await m.addBoard(name: "Show")
        await m.importTracks([try makeTone(), try makeTone()])
        var a = m.boards[0].tracks[0]; let b = m.boards[0].tracks[1]
        a.automations = [Automation(trigger: .started, action: .play, target: b.id)]
        await m.update(a)
        m.tap(a.id)
        #expect(m.playing == [a.id, b.id])
        m.tap(a.id)  // second tap stops
        #expect(!m.playing.contains(a.id))
    }

    @Test func moveTracksPersistsOrder() async throws {
        let (m, store) = try makeModel()
        await m.addBoard(name: "Show")
        await m.importTracks([try makeTone(), try makeTone(), try makeTone()])
        let ids = m.boards[0].tracks.map(\.id)
        await m.moveTrack(ids[2], before: ids[0])
        let (m2, _) = try makeModel(store: store)
        await m2.load()
        #expect(m2.boards[0].tracks.map(\.id) == [ids[2], ids[0], ids[1]])
    }

    @Test func moveBoardPersistsOrder() async throws {
        let (m, store) = try makeModel()
        await m.addBoard(name: "A"); await m.addBoard(name: "B")
        await m.moveBoard(m.boards[1].id, before: m.boards[0].id)
        let (m2, _) = try makeModel(store: store)
        await m2.load()
        #expect(m2.boards.map(\.name) == ["B", "A"])
    }

    @Test func missingAudioTapIsNoOp() async throws {
        let (m, store) = try makeModel()
        let t = Track(id: UUID(), name: "x", fileName: "gone.wav", colorHex: "#000000")
        try await store.save(Board(id: UUID(), name: "Show", colorHex: "#000000", tracks: [t]))
        await m.load()
        m.tap(t.id)
        #expect(m.unavailable == [t.id])
        #expect(m.playing.isEmpty)
        #expect(m.engine.activeVoiceCount == 0)
    }

    func makeUD() -> UserDefaults { UserDefaults(suiteName: UUID().uuidString)! }
    func oneTrack(_ m: AppModel) async throws -> Track {
        await m.addBoard(name: "Show"); await m.importTracks([try makeTone()]); return m.boards[0].tracks[0]
    }

    @Test func updateSettingsPersists() async throws {
        let (m, store) = try makeModel()
        var t = try await oneTrack(m)
        t.settings.volume = 0.4; t.settings.loop = true; t.colorHex = "#123456"
        await m.update(t)
        let (m2, _) = try makeModel(store: store); await m2.load()
        #expect(m2.boards[0].tracks[0] == t)
    }

    @Test func defaultsAppliedToNewImports() async throws {
        let ud = makeUD()
        let s = try LocalBoardStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let m = AppModel(store: s, manualRendering: true, userDefaults: ud)
        var d = TrackSettings.default; d.volume = 0.5; d.fadeIn = 1
        m.defaults = d
        let t = try await oneTrack(m)
        #expect(t.settings.volume == 0.5 && t.settings.fadeIn == 1)
        #expect(AppModel(store: s, manualRendering: true, userDefaults: ud).defaults == d)  // persisted
    }

    @Test func trimChangeClampsAndPersists() async throws {
        let (m, store) = try makeModel()
        let t = try await oneTrack(m)   // 1 s tone
        await m.setTrim(t.id, trimIn: 0.2, trimOut: 0.1)   // out before in -> ignored
        #expect(m.boards[0].tracks[0].settings.trimIn == 0.2 && m.boards[0].tracks[0].settings.trimOut == nil)
        await m.setTrim(t.id, trimIn: 5, trimOut: 99)      // beyond the file -> clamped
        let s = m.boards[0].tracks[0].settings
        #expect(s.trimIn < 1 && s.trimIn > 0.9 && s.trimOut == nil)
        let (m2, _) = try makeModel(store: store); await m2.load()
        #expect(m2.boards[0].tracks[0].settings == s)
    }

    @Test func addAndRemoveAutomation() async throws {
        let (m, _) = try makeModel()
        await m.addBoard(name: "Show"); await m.importTracks([try makeTone(), try makeTone()])
        let a = m.boards[0].tracks[0], b = m.boards[0].tracks[1]
        await m.addAutomation(to: a.id, Automation(trigger: .ended, action: .play, target: b.id))
        await m.addAutomation(to: a.id, Automation(trigger: .ended, action: .play, target: a.id))      // self: rejected
        await m.addAutomation(to: a.id, Automation(trigger: .ended, action: .play, target: UUID()))    // unknown: rejected
        #expect(m.boards[0].tracks[0].automations.count == 1)
        await m.removeAutomation(from: a.id, at: 0)
        #expect(m.boards[0].tracks[0].automations.isEmpty)
    }

    @Test func deleteTrackRemovesTileAndReferences() async throws {
        let (m, _) = try makeModel()
        await m.addBoard(name: "Show"); await m.importTracks([try makeTone(), try makeTone()])
        let a = m.boards[0].tracks[0], b = m.boards[0].tracks[1]
        await m.addAutomation(to: a.id, Automation(trigger: .ended, action: .play, target: b.id))
        m.tap(b.id)
        await m.deleteTrack(b.id)
        #expect(m.boards[0].tracks.map(\.id) == [a.id])
        #expect(m.boards[0].tracks[0].automations.isEmpty)
        #expect(m.playing.isEmpty)
    }

    @Test func setImageStoresFileAndName() async throws {
        let (m, store) = try makeModel()
        let t = try await oneTrack(m)
        let img = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600)).image { c in
            UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        }
        await m.setImage(t.id, data: img.pngData()!)
        let name = try #require(m.boards[0].tracks[0].imageFileName)
        #expect(try await store.audioURL(board: m.boards[0].id, fileName: name) != nil)
        await m.setImage(t.id, data: nil)
        #expect(m.boards[0].tracks[0].imageFileName == nil)
    }

    @Test func editAppliesImmediately() async throws {
        let (m, _) = try makeModel()
        let t = try await oneTrack(m)
        m.edit(t.id) { $0.name = "Renamed"; $0.settings.solo = true }
        #expect(m.track(t.id)?.name == "Renamed" && m.track(t.id)?.settings.solo == true)  // synchronous
    }

    @Test func syncNowCopiesBoardToCloud() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (local, cloud) = (base.appendingPathComponent("l"), base.appendingPathComponent("c"))
        let m = AppModel(store: LocalBoardStore(root: local), manualRendering: true, userDefaults: makeUD(),
                         sync: SyncConfig(local: local, cloud: { cloud }))
        await m.addBoard(name: "Show")
        await m.syncNow()
        #expect(FileManager.default.fileExists(atPath: cloud.appendingPathComponent("Show/board.json").path))
        #expect(m.syncStatus.contains("Synced"))
    }

    @Test func syncNowWithoutICloudSaysSo() async throws {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let m = AppModel(store: LocalBoardStore(root: local), manualRendering: true, userDefaults: makeUD(),
                         sync: SyncConfig(local: local, cloud: { nil }))
        await m.addBoard(name: "Show")
        await m.syncNow()
        #expect(m.syncStatus.contains("not available"))
        #expect(m.boards.count == 1)   // playback/editing unaffected
    }

    @Test func syncReloadsEvenWhilePlaying() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (local, cloud) = (base.appendingPathComponent("l"), base.appendingPathComponent("c"))
        let m = AppModel(store: LocalBoardStore(root: local), manualRendering: true, userDefaults: makeUD(),
                         sync: SyncConfig(local: local, cloud: { cloud }))
        await m.addBoard(name: "Show"); await m.importTracks([try makeTone()])
        var t = m.boards[0].tracks[0]; t.settings.loop = true   // keeps playing for the whole test
        await m.update(t)
        await m.syncNow()
        // another device changes the board colour in iCloud (newer mtime)
        let url = cloud.appendingPathComponent("Show/board.json")
        var b = try JSONDecoder().decode(Board.self, from: Data(contentsOf: url))
        b.colorHex = "#ABCDEF"
        try JSONEncoder().encode(b).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        m.tap(m.boards[0].tracks[0].id)
        #expect(!m.playing.isEmpty)
        await m.syncNow()
        #expect(!m.playing.isEmpty)   // still playing: the reload must happen anyway
        #expect(m.boards[0].colorHex == "#ABCDEF")   // a stale in-memory board must never overwrite synced data
    }
}

@MainActor @Suite struct SharedFileTests {
    @Test func buttonsFromOneFileShareIt() async throws {
        let s = try LocalBoardStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let m = AppModel(store: s, manualRendering: true, userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        await m.addBoard(name: "Show")
        await m.importTracks([try makeTone(seconds: 4)])
        let src = m.boards[0].tracks[0]
        let ids = await m.addExcerpts(from: src.id, [(name: "A", subtitle: "2 bars", start: 0.5, end: 1.5), (name: "B", subtitle: nil, start: 2, end: 3)])
        let tracks = m.boards[0].tracks
        #expect(tracks.count == 3 && ids.count == 2)
        #expect(tracks.allSatisfy { $0.fileName == src.fileName })       // one audio file, three buttons
        let a = try #require(m.track(ids[0]))
        #expect(a.settings.trimIn == 0.5 && a.settings.trimOut == 1.5 && a.settings.loop)
        #expect(a.subtitle == "2 bars")
        #expect(m.unavailable.isEmpty)
        #expect(m.engine.playRange(a.id) == 0.5...1.5)
    }

    @Test func previewPlaysARangeWithoutChangingTheTrack() async throws {
        let s = try LocalBoardStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let m = AppModel(store: s, manualRendering: true, userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        await m.addBoard(name: "Show")
        await m.importTracks([try makeTone(seconds: 4)])
        let src = m.boards[0].tracks[0]
        await m.preview(src.id, start: 1, end: 2)
        #expect(m.playing.count == 1 && !m.playing.contains(src.id))
        #expect(m.track(src.id) == src && m.boards[0].tracks.count == 1)
        m.stopPreview()
        #expect(m.playing.isEmpty)
    }
}
