import Foundation
import Testing
@testable import SoundTablet

@MainActor @Suite struct NormalizeTests {
    @Test func loudnessIsRMSInDBFS() async throws {
        let half = try await loudnessDB(url: try makeTone(amplitude: 0.5))
        let quarter = try await loudnessDB(url: try makeTone(amplitude: 0.25))
        #expect(abs(half - -9.03) < 0.1)       // 0.5/sqrt2
        #expect(abs((half - quarter) - 6.02) < 0.1)
    }

    @Test func gainOnlyAttenuates() {
        #expect(abs(normalizationGain(trackDB: -9, referenceDB: -15) - 0.5) < 0.01)
        #expect(normalizationGain(trackDB: -20, referenceDB: -15) == 1)  // quieter than reference: unchanged
    }

    @Test func oldBoardJSONWithoutNormalizeFieldsStillDecodes() throws {
        let s = try JSONDecoder().decode(TrackSettings.self, from: Data(#"{"volume":0.8,"loop":true}"#.utf8))
        #expect(s.volume == 0.8 && s.loop && !s.normalize && s.loudnessDB == nil)
    }

    @Test func engineScalesVolumeByGain() throws {
        let e = AudioEngine(onEvent: { _ in }, manualRendering: true)
        e.referenceDB = -15
        var t = Track(id: UUID(), name: "t", fileName: "t.wav", colorHex: "#000000")
        t.settings.normalize = true; t.settings.loudnessDB = -9
        try e.load(t, url: try makeTone())
        e.play(t.id)
        #expect(abs((e.volume(t.id) ?? 0) - 0.5) < 0.01)
        e.setVolume(t.id, 0.5)
        #expect(abs((e.volume(t.id) ?? 0) - 0.25) < 0.01)
    }

    @Test func modelMeasuresReferenceAndTrack() async throws {
        let s = try LocalBoardStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let m = AppModel(store: s, manualRendering: true, userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        await m.addBoard(name: "Show")
        await m.importTracks([try makeTone(amplitude: 0.5)])
        let id = m.boards[0].tracks[0].id
        await m.setReference(try makeTone(amplitude: 0.25))
        await m.setNormalize(id, true)
        let t = try #require(m.track(id))
        #expect(t.settings.normalize)
        #expect(abs((t.settings.loudnessDB ?? 0) - -9.03) < 0.1)
        #expect(abs((m.referenceDB ?? 0) - -15.05) < 0.1)
        m.tap(id)
        #expect(abs((m.engine.volume(id) ?? 0) - 0.5) < 0.02)
    }
}
