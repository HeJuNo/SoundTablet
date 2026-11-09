import Foundation
import Testing
@testable import SoundTablet

@MainActor final class FakeControl: TrackControl {
    var calls: [String] = []
    var engine: AutomationEngine?
    var board: Board?
    func play(_ id: Track.ID) {
        calls.append("play \(id)")
        if let e = engine, let b = board { e.handle(.started(id), board: b, control: self) }
    }
    func stop(_ id: Track.ID) { calls.append("stop \(id)") }
    func setVolume(_ id: Track.ID, _ v: Float) { calls.append("vol \(id) \(v)") }
}

@MainActor @Suite struct AutomationEngineTests {
    func track(_ autos: [Automation] = []) -> Track {
        var t = Track(id: UUID(), name: "t", fileName: "t.wav", colorHex: "#000000"); t.automations = autos; return t
    }

    @Test func startedTriggersSetVolume() {
        let b = track()
        let a = track([Automation(trigger: .started, action: .setVolume(0.3), target: b.id)])
        let board = Board(id: UUID(), name: "x", colorHex: "#000", tracks: [a, b])
        let c = FakeControl()
        AutomationEngine().handle(.started(a.id), board: board, control: c)
        #expect(c.calls == ["vol \(b.id) 0.3"])
    }

    @Test func endedTriggersPlayNext() {
        let b = track()
        let a = track([Automation(trigger: .ended, action: .play, target: b.id)])
        let board = Board(id: UUID(), name: "x", colorHex: "#000", tracks: [a, b])
        let c = FakeControl()
        AutomationEngine().handle(.ended(a.id), board: board, control: c)
        #expect(c.calls == ["play \(b.id)"])
    }

    @Test func unrelatedEventDoesNothing() {
        let b = track()
        let a = track([Automation(trigger: .ended, action: .play, target: b.id)])
        let board = Board(id: UUID(), name: "x", colorHex: "#000", tracks: [a, b])
        let c = FakeControl()
        AutomationEngine().handle(.started(a.id), board: board, control: c)
        AutomationEngine().handle(.stopped(a.id), board: board, control: c)
        #expect(c.calls.isEmpty)
    }

    @Test func cycleStopsAtDepth8() {
        var a = track(), b = track()
        a.automations = [Automation(trigger: .started, action: .play, target: b.id)]
        b.automations = [Automation(trigger: .started, action: .play, target: a.id)]
        let board = Board(id: UUID(), name: "x", colorHex: "#000", tracks: [a, b])
        let c = FakeControl(), e = AutomationEngine()
        c.engine = e; c.board = board
        e.handle(.started(a.id), board: board, control: c)
        #expect(c.calls.count == 8)
    }
}
