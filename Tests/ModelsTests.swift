import Foundation
import Testing
@testable import SoundTablet

@Suite struct ModelsTests {
    @Test func roundTrip() throws {
        let target = UUID()
        var track = Track(id: UUID(), name: "Intro", fileName: "a.wav", colorHex: "#FF0000")
        track.automations = [Automation(trigger: .started, action: .setVolume(0.3), target: target)]
        let board = Board(id: UUID(), name: "Show", colorHex: "#00FF00", tracks: [track])
        let data = try JSONEncoder().encode(board)
        #expect(try JSONDecoder().decode(Board.self, from: data) == board)
    }

    @Test func defaultSettings() {
        let s = TrackSettings.default
        #expect(s.volume == 1)
        #expect(s.loop == false)
        #expect(s.trimIn == 0)
        #expect(s.trimOut == nil)
    }
}
