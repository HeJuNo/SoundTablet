import Foundation
import Testing
@testable import SoundTablet

@MainActor @Suite struct SoundboardStudioImportTests {
    /// Folder shaped like the app's export: one board with three buttons (one with a decomposed accent in the JSON, one without audio), one empty board.
    func makeFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in ["a.mp3", "Délicia.mp3"] { try FileManager.default.copyItem(at: makeTone(), to: dir.appendingPathComponent(n)) }
        func track(_ id: String, _ title: String, _ file: String, order: Int, next: Bool = false, fadeIn: Bool = false, trimOut: Double = 4) -> String {
            """
            "\(id)": {"id":"\(id)","title":"\(title)","file":"\(file)","board":"b1","colorScheme":"blue","order":\(order),"volume":0.5,
            "loops":true,"solo":true,"fadesIn":\(fadeIn),"fadesOut":false,"playsNext":\(next),"fadesInDuration":3,"fadesOutDuration":0.4,
            "trimInPoint":1,"trimOutPoint":\(trimOut),"fullDuration":4,"pan":0,"animates":true,"hasPlayed":false,"trackType":"track"}
            """
        }
        let json = """
        {"boards":{"b1":{"id":"b1","title":"Songs","colorScheme":"white","order":1},"b0":{"id":"b0","title":"Intro","colorScheme":"red","order":0}},
         "tracks":{\(track("t1", "One", "a.mp3", order: 0, next: true, fadeIn: true, trimOut: 3)),
                   \(track("t2", "Two", "De\u{0301}licia.mp3", order: 1)), \(track("t3", "Gone", "missing.mp3", order: 2))},"app":{}}
        """
        try json.write(to: dir.appendingPathComponent("soundboard.json"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func mapsBoardsButtonsAndSettings() throws {
        let r = try SoundboardStudioImport.read(makeFolder())
        #expect(r.boards.map(\.name) == ["Intro", "Songs"])          // by the app's board order
        #expect(r.boards[1].colorHex == tilePalette[7] && r.boards[0].colorHex == tilePalette[0])
        let songs = r.boards[1].tracks
        #expect(songs.map(\.name) == ["One", "Two"] && r.skipped == ["Gone"])
        let s = songs[0].settings
        #expect(s.volume == 0.5 && s.loop && s.solo && s.fadeIn == 3 && s.fadeOut == 0 && s.trimIn == 1 && s.trimOut == 3)
        #expect(songs[1].settings.trimOut == nil)                      // trim end at the file end = untrimmed
        #expect(songs[0].automations == [Automation(trigger: .ended, action: .play, target: songs[1].id)])
        #expect(songs[1].fileName == "Délicia.mp3" && songs[0].colorHex == tilePalette[4])
    }

    @Test func importCopiesAudioIntoNewBoards() async throws {
        let store = try LocalBoardStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let m = AppModel(store: store, manualRendering: true)
        await m.addBoard(name: "Existing")
        let msg = await m.importSoundboardStudio(try makeFolder())
        #expect(m.boards.map(\.name) == ["Existing", "Intro", "Songs"] && m.boards.map(\.sortIndex) == [0, 1, 2])
        #expect(msg.contains("2 boards, 2 buttons") && msg.contains("1 skipped"))
        let t = try #require(m.boards[2].tracks.first)
        #expect(try await store.audioURL(board: m.boards[2].id, fileName: t.fileName) != nil && m.unavailable.isEmpty)
        #expect(try await store.loadBoards().count == 3)
    }
}
