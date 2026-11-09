import AVFoundation
import Foundation
import Testing
@testable import SoundTablet

/// 1 s (default) 440 Hz mono tone written to a temp wav.
func makeTone(seconds: Double = 1, amplitude: Float = 0.5) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    let frames = AVAudioFrameCount(44100 * seconds)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
    buf.frameLength = frames
    for i in 0..<Int(frames) { buf.floatChannelData![0][i] = amplitude * sinf(2 * .pi * 440 * Float(i) / 44100) }
    try AVAudioFile(forWriting: url, settings: fmt.settings).write(from: buf)
    return url
}

@MainActor final class EventLog { var events: [PlaybackEvent] = [] }

@MainActor @Suite struct AudioEngineTests {
    func track(solo: Bool = false, loop: Bool = false) -> Track {
        var t = Track(id: UUID(), name: "t", fileName: "t.wav", colorHex: "#000000")
        t.settings.solo = solo; t.settings.loop = loop; return t
    }
    func makeEngine() -> (AudioEngine, EventLog) {
        let log = EventLog()
        return (AudioEngine(onEvent: { log.events.append($0) }, manualRendering: true), log)
    }
    func waitFor(_ cond: () -> Bool) async {
        for _ in 0..<100 where !cond() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func clampedTrimHandlesOutBeforeIn() {
        #expect(AudioEngine.clampedTrim(inTime: 5, out: 2, duration: 10) == 5...10)
    }
    @Test func clampedTrimBeyondDuration() {
        #expect(AudioEngine.clampedTrim(inTime: 2, out: 99, duration: 10) == 2...10)
        #expect(AudioEngine.clampedTrim(inTime: -3, out: nil, duration: 10) == 0...10)
    }

    @Test func playEmitsStartedThenEnded() async throws {
        let (e, log) = makeEngine(); let t = track()
        try e.load(t, url: try makeTone())
        e.play(t.id)
        #expect(e.isPlaying(t.id))
        try e.renderOffline(seconds: 1.5)
        await waitFor { log.events.count == 2 }
        #expect(log.events == [.started(t.id), .ended(t.id)])
        #expect(!e.isPlaying(t.id))
    }

    @Test func retapRestartsSingleNode() throws {
        let (e, log) = makeEngine(); let t = track()
        try e.load(t, url: try makeTone())
        e.play(t.id); e.play(t.id)
        #expect(e.activeVoiceCount == 1)
        #expect(log.events == [.started(t.id), .stopped(t.id), .started(t.id)])
    }

    @Test func soloStopsOthers() throws {
        let (e, log) = makeEngine(); let a = track(), b = track(solo: true)
        try e.load(a, url: try makeTone()); try e.load(b, url: try makeTone())
        e.play(a.id); e.play(b.id)
        #expect(!e.isPlaying(a.id) && e.isPlaying(b.id))
        #expect(log.events == [.started(a.id), .stopped(a.id), .started(b.id)])
    }

    @Test func loopRepeats() async throws {
        let (e, log) = makeEngine(); let t = track(loop: true)
        try e.load(t, url: try makeTone())
        e.play(t.id)
        try e.renderOffline(seconds: 2.5)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(e.isPlaying(t.id))
        #expect(log.events == [.started(t.id)])
        e.stop(t.id)
        #expect(log.events.last == .stopped(t.id))
    }

    func interruption(_ type: AVAudioSession.InterruptionType) {
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                                        userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue])
    }

    @Test func interruptionStopsAndEngineRestarts() throws {
        let (e, log) = makeEngine(); let t = track()
        try e.load(t, url: try makeTone())
        e.play(t.id)
        interruption(.began)
        #expect(!e.isPlaying(t.id) && e.activeVoiceCount == 0)
        #expect(log.events == [.started(t.id), .stopped(t.id)])
        interruption(.ended)
        e.play(t.id)
        #expect(e.isPlaying(t.id))
    }

    @Test func configurationChangeResetsVoicesAndRestartsEngine() throws {
        let (e, log) = makeEngine(); let t = track()
        try e.load(t, url: try makeTone())
        e.play(t.id)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: e.avEngine)
        #expect(log.events == [.started(t.id), .stopped(t.id)])
        e.play(t.id)
        #expect(e.isPlaying(t.id))
    }

    struct StartFailure: Error {}

    @Test func playWhenEngineCannotStartDoesNotCrash() throws {
        let (e, log) = makeEngine(); let t = track()
        try e.load(t, url: try makeTone())
        e.startEngine = { throw StartFailure() }   // e.g. during a phone call
        e.play(t.id)
        #expect(!e.isPlaying(t.id) && e.activeVoiceCount == 0)
        #expect(log.events.isEmpty)
        e.resumeAll()   // must not crash either
    }

    @Test func seekToEndEndsTrack() throws {
        let (e, log) = makeEngine(); let t = track()
        try e.load(t, url: try makeTone())
        e.play(t.id)
        e.seek(t.id, to: 99)
        #expect(!e.isPlaying(t.id))
        #expect(log.events == [.started(t.id), .ended(t.id)])
    }
}
