import Foundation

enum PlaybackEvent: Equatable, Sendable {
    case started(Track.ID), stopped(Track.ID), ended(Track.ID)

    var trackID: Track.ID {
        switch self { case .started(let i), .stopped(let i), .ended(let i): i }
    }
    var trigger: AutomationTrigger {
        switch self { case .started: .started; case .stopped: .stopped; case .ended: .ended }
    }
}

@MainActor protocol TrackControl: AnyObject {
    func play(_ id: Track.ID)
    func stop(_ id: Track.ID)
    func setVolume(_ id: Track.ID, _ v: Float)
}

@MainActor final class AutomationEngine {
    private let maxDepth: Int
    private var depth = 0
    init(maxDepth: Int = 8) { self.maxDepth = maxDepth }

    /// Re-entrant: actions that raise new events call back in; the depth counter caps cycles.
    func handle(_ e: PlaybackEvent, board: Board, control: TrackControl) {
        guard depth < maxDepth else { return }
        depth += 1
        defer { depth -= 1 }
        guard let track = board.tracks.first(where: { $0.id == e.trackID }) else { return }
        for a in track.automations where a.trigger == e.trigger {
            switch a.action {
            case .play: control.play(a.target)
            case .stop: control.stop(a.target)
            case .setVolume(let v): control.setVolume(a.target, v)
            }
        }
    }
}
