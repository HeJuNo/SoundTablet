import AVFoundation
import Foundation

/// Latest RMS per voice, written from the audio thread, read by the UI.
private final class LevelStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: Float] = [:]
    func set(_ id: UUID, _ v: Float) { lock.withLock { values[id] = v } }
    func get(_ id: UUID) -> Float { lock.withLock { values[id] ?? 0 } }
    func clear(_ id: UUID) { lock.withLock { values[id] = nil } }
}

@MainActor final class AudioEngine: TrackControl {
    private struct Loaded { var track: Track; var url: URL; var sampleRate: Double; var duration: Double }

    private final class Voice: @unchecked Sendable {
        let node = AVAudioPlayerNode()
        var offset: Double          // file time where the current schedule started
        var epoch = 0               // bumped on seek/stop so stale completions are ignored
        var fadeTask: Task<Void, Never>?
        var paused = false          // paused by a tap: voice is kept so the next tap can continue
        var pausedAt: Double?       // file time at the pause (playerTime is not reliable on a paused node)
        init(offset: Double) { self.offset = offset }
    }

    private let engine = AVAudioEngine()
    private let onEvent: @MainActor (PlaybackEvent) -> Void
    private let manualRendering: Bool
    private let levels = LevelStore()
    private var loaded: [Track.ID: Loaded] = [:]
    private var voices: [Track.ID: Voice] = [:]

    init(onEvent: @escaping @MainActor (PlaybackEvent) -> Void, manualRendering: Bool = false) {
        self.onEvent = onEvent
        self.manualRendering = manualRendering
        if manualRendering {
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            try? engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        // Weak self + main queue: tokens are intentionally not removed, the engine lives as long as the app.
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            MainActor.assumeIsolated { self?.handleInterruption(type) }
        }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetAndRestart() }
        }
    }

    /// A call, Siri or another app took the audio: playing state is reset (honest tiles), playback resumes only on the next tap.
    private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        switch type {
        case .began: for (id, v) in voices { finish(id, v, event: .stopped(id)) }
        case .ended:
            // No eager engine.start(): with no node attached it raises an ObjC exception; play() restarts it lazily.
            if !manualRendering { try? AVAudioSession.sharedInstance().setActive(true) }
        default: break
        }
    }

    /// The system tore the engine down (route/format change): drop all voices; the next play() restarts the engine.
    private func resetAndRestart() {
        for (id, v) in voices { finish(id, v, event: .stopped(id)) }
    }

    /// Overridable so tests can simulate a failing start (e.g. during a phone call).
    lazy var startEngine: () throws -> Void = { [engine] in try engine.start() }
    var activeVoiceCount: Int { voices.count }
    var avEngine: AVAudioEngine { engine }  // exposed for tests (configuration-change notification)

    // MARK: loading

    func load(_ track: Track, url: URL) throws {
        let f = try AVAudioFile(forReading: url)
        loaded[track.id] = Loaded(track: track, url: url, sampleRate: f.processingFormat.sampleRate,
                                  duration: Double(f.length) / f.processingFormat.sampleRate)
    }

    func duration(_ id: Track.ID) -> Double? { loaded[id]?.duration }
    func unload(_ id: Track.ID) { loaded[id] = nil }

    nonisolated static func clampedTrim(inTime: Double, out: Double?, duration: Double) -> ClosedRange<Double> {
        let lower = min(max(inTime, 0), duration)
        let upper = out.map { min($0, duration) } ?? duration
        return lower...(upper > lower ? upper : duration)  // out <= in: ignore out, play to the end
    }

    // MARK: transport

    /// `from` starts inside the trimmed range (editor playhead); outside of it, or at the very end, playback starts at the trim start.
    func play(_ id: Track.ID) { play(id, from: nil) }
    func play(_ id: Track.ID, from: Double?) {
        guard let l = loaded[id] else { return }
        let s = l.track.settings
        let range = Self.clampedTrim(inTime: s.trimIn, out: s.trimOut, duration: l.duration)
        guard range.upperBound > range.lowerBound, let file = try? AVAudioFile(forReading: l.url) else { return }
        if s.solo { for other in voices.keys where other != id { stop(other) } }
        if voices[id] != nil { stop(id) }
        let start = from.flatMap { range.contains($0) && $0 < range.upperBound - 0.01 ? $0 : nil } ?? range.lowerBound

        let v = Voice(offset: start)
        engine.attach(v.node)
        engine.connect(v.node, to: engine.mainMixerNode, format: file.processingFormat)
        v.node.volume = s.fadeIn > 0 ? 0 : s.volume * gain(s)
        v.node.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable [levels] buf, _ in
            guard let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
            levels.set(id, min(1, (sum / Float(buf.frameLength)).squareRoot() * 2))
        }
        voices[id] = v
        schedule(id, v, file: file, from: start, range: range, loop: s.loop, copies: s.loop ? 2 : 1)
        if !engine.isRunning { try? startEngine() }
        guard engine.isRunning else {  // e.g. during a call: node.play() would raise an ObjC exception and kill the app
            v.node.removeTap(onBus: 0)
            engine.detach(v.node)
            voices[id] = nil
            levels.clear(id)
            return
        }
        v.node.play()
        onEvent(.started(id))

        if s.fadeIn > 0 { fade(v, to: s.volume * gain(s), over: s.fadeIn) }
        if !s.loop { scheduleFadeOut(v, fadeOut: s.fadeOut, remaining: range.upperBound - start) }
    }

    /// Fades to silence so the track is silent when its range ends. shortcut: wall-clock timer, drifts if the
    /// engine stalls; use a render-synced ramp if it ever matters.
    private func scheduleFadeOut(_ v: Voice, fadeOut out: Double, remaining: Double) {
        guard out > 0 else { return }
        let delay = max(0, remaining - out)
        v.fadeTask = Task { [weak self, weak v] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, let v, !Task.isCancelled else { return }
            self.fade(v, to: 0, over: min(out, remaining))
        }
    }

    private func schedule(_ id: Track.ID, _ v: Voice, file: AVAudioFile, from start: Double,
                          range: ClosedRange<Double>, loop: Bool, copies: Int) {
        let sr = file.processingFormat.sampleRate
        let first = AVAudioFramePosition(start * sr)
        let end = AVAudioFramePosition(range.upperBound * sr)
        guard end > first else { return }
        let epoch = v.epoch  // offline rendering has no output clock, so .dataPlayedBack never fires there
        for i in 0..<copies {
            let from = i == 0 ? first : AVAudioFramePosition(range.lowerBound * sr)
            v.node.scheduleSegment(file, startingFrame: from, frameCount: AVAudioFrameCount(end - from),
                                   at: nil, completionCallbackType: manualRendering ? .dataConsumed : .dataPlayedBack) { @Sendable [weak self] _ in
                Task { @MainActor in
                    guard let self, let cur = self.voices[id], cur === v, cur.epoch == epoch else { return }
                    if loop {  // keep one segment queued ahead for gapless looping
                        self.schedule(id, v, file: file, from: range.lowerBound, range: range, loop: true, copies: 1)
                    } else {
                        self.finish(id, v, event: .ended(id))
                    }
                }
            }
        }
    }

    private func finish(_ id: Track.ID, _ v: Voice, event: PlaybackEvent?) {
        v.epoch += 1
        v.fadeTask?.cancel()
        v.node.removeTap(onBus: 0)
        v.node.stop()
        engine.detach(v.node)
        voices[id] = nil
        levels.clear(id)
        if let event { onEvent(event) }
    }

    /// Pauses at the current position (with the track's fade-out, if any). Emits `.stopped`, like a stop did before.
    func pause(_ id: Track.ID) {
        guard let v = voices[id], !v.paused else { return }
        v.paused = true
        v.fadeTask?.cancel()
        onEvent(.stopped(id))
        let out = loaded[id]?.track.settings.fadeOut ?? 0
        let freeze: @MainActor () -> Void = { [weak self, weak v] in
            guard let self, let v, v.paused, self.voices[id] === v else { return }
            v.pausedAt = self.position(id)
            v.node.pause()
        }
        if out > 0 { fade(v, to: 0, over: out, done: freeze) } else { freeze() }
    }

    /// Continues a paused voice where it stopped; if the engine is gone the voice is dropped instead.
    func resume(_ id: Track.ID) {
        guard let v = voices[id], v.paused, let l = loaded[id] else { return }
        if !engine.isRunning { try? startEngine() }
        guard engine.isRunning else { finish(id, v, event: nil); return }
        let s = l.track.settings
        let range = Self.clampedTrim(inTime: s.trimIn, out: s.trimOut, duration: l.duration)
        let from = v.pausedAt ?? position(id) ?? range.lowerBound
        v.paused = false
        v.pausedAt = nil
        v.fadeTask?.cancel()
        let remaining = range.upperBound - from
        v.node.volume = s.volume * gain(s) * ((s.fadeOut > 0 && !s.loop && remaining < s.fadeOut) ? Float(max(0, remaining) / s.fadeOut) : 1)
        v.node.play()
        onEvent(.started(id))
        if !s.loop { scheduleFadeOut(v, fadeOut: s.fadeOut, remaining: remaining) }
    }

    /// Drops a paused voice without an event (another button was pressed: the paused state is reset).
    func release(_ id: Track.ID) {
        if let v = voices[id], v.paused { finish(id, v, event: nil) }
    }

    func stop(_ id: Track.ID) { stop(id, fadeOut: nil) }

    func stop(_ id: Track.ID, fadeOut: Double?) {
        guard let v = voices[id] else { return }
        guard let d = fadeOut, d > 0 else { finish(id, v, event: .stopped(id)); return }
        v.epoch += 1  // natural end must not fire during the fade
        fade(v, to: 0, over: d) { [weak self] in
            guard let self, self.voices[id] === v else { return }
            self.finish(id, v, event: .stopped(id))
        }
    }

    func setVolume(_ id: Track.ID, _ v: Float) {
        loaded[id]?.track.settings.volume = v
        if let s = loaded[id]?.track.settings { voices[id]?.node.volume = v * gain(s) }
    }

    /// Reference loudness (dBFS) that tracks with `normalize` are attenuated to; nil = normalization off.
    var referenceDB: Double?
    private func gain(_ s: TrackSettings) -> Float {
        guard s.normalize, let r = referenceDB, let l = s.loudnessDB else { return 1 }
        return normalizationGain(trackDB: l, referenceDB: r)
    }
    func volume(_ id: Track.ID) -> Float? { voices[id]?.node.volume }  // for tests

    func pauseAll() { voices.values.filter { !$0.paused }.forEach { $0.node.pause() } }
    func resumeAll() { if engine.isRunning { voices.values.filter { !$0.paused }.forEach { $0.node.play() } } }
    func stopAll(fadeOut: Double) { for id in Array(voices.keys) { stop(id, fadeOut: fadeOut) } }
    func isPlaying(_ id: Track.ID) -> Bool { voices[id] != nil }
    func level(_ id: Track.ID) -> Float { levels.get(id) }

    /// Trimmed play range in seconds (for scrub sliders); nil when the track is not loaded.
    func playRange(_ id: Track.ID) -> ClosedRange<Double>? {
        guard let l = loaded[id] else { return nil }
        return Self.clampedTrim(inTime: l.track.settings.trimIn, out: l.track.settings.trimOut, duration: l.duration)
    }

    func position(_ id: Track.ID) -> Double? {
        if let v = voices[id], v.paused, let p = v.pausedAt { return p }
        guard let v = voices[id], let l = loaded[id],
              let nt = v.node.lastRenderTime, nt.isSampleTimeValid || nt.isHostTimeValid, let pt = v.node.playerTime(forNodeTime: nt) else { return nil }
        let s = l.track.settings
        let range = Self.clampedTrim(inTime: s.trimIn, out: s.trimOut, duration: l.duration)
        var elapsed = (v.offset - range.lowerBound) + Double(pt.sampleTime) / pt.sampleRate
        if s.loop { elapsed = elapsed.truncatingRemainder(dividingBy: range.upperBound - range.lowerBound) }
        return range.lowerBound + max(0, elapsed)
    }

    func seek(_ id: Track.ID, to time: Double) {
        guard let v = voices[id], !v.paused, let l = loaded[id], let file = try? AVAudioFile(forReading: l.url) else { return }
        let s = l.track.settings
        let range = Self.clampedTrim(inTime: s.trimIn, out: s.trimOut, duration: l.duration)
        guard engine.isRunning else { finish(id, v, event: .stopped(id)); return }
        var t = min(max(time, range.lowerBound), range.upperBound)
        if t >= range.upperBound - 1 / l.sampleRate {  // scrubbed to the very end: nothing left to schedule
            if s.loop { t = range.lowerBound } else { finish(id, v, event: .ended(id)); return }
        }
        v.epoch += 1
        v.node.stop()
        v.offset = t
        schedule(id, v, file: file, from: t, range: range, loop: s.loop, copies: s.loop ? 2 : 1)
        v.node.play()
        // The fade timers belong to the old position: restart them for the new one (a fade-in cut short just jumps to full volume).
        v.fadeTask?.cancel()
        let remaining = range.upperBound - t
        v.node.volume = s.volume * gain(s) * ((s.fadeOut > 0 && !s.loop && remaining < s.fadeOut) ? Float(max(0, remaining) / s.fadeOut) : 1)
        if !s.loop { scheduleFadeOut(v, fadeOut: s.fadeOut, remaining: remaining) }
    }

    // MARK: helpers

    /// shortcut: 20 ms main-actor steps (not sample-accurate); move to a mixer automation if fades need to be exact.
    private func fade(_ v: Voice, to target: Float, over duration: Double, done: (@MainActor () -> Void)? = nil) {
        v.fadeTask?.cancel()
        let from = v.node.volume
        v.fadeTask = Task { @MainActor [weak v] in
            let steps = max(1, Int(duration / 0.02))
            for i in 1...steps {
                try? await Task.sleep(for: .milliseconds(20))
                guard let v, !Task.isCancelled else { return }
                v.node.volume = from + (target - from) * Float(i) / Float(steps)
            }
            done?()
        }
    }

    /// Offline-rendering pump for tests (manualRendering: true only).
    func renderOffline(seconds: Double) throws {
        let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                   frameCapacity: engine.manualRenderingMaximumFrameCount)!
        var remaining = AVAudioFrameCount(seconds * engine.manualRenderingFormat.sampleRate)
        while remaining > 0 {
            let n = min(remaining, buf.frameCapacity)
            _ = try engine.renderOffline(n, to: buf)
            remaining -= n
        }
    }
}
