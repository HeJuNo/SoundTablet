import AVFoundation

/// A suggested excerpt of an audio file: a loop of N bars at the detected tempo, or a section between silences.
struct LoopCandidate: Identifiable, Equatable, Sendable {
    let id = UUID()
    var title: String
    var detail: String
    var start: Double
    var end: Double
    var bpm: Double? = nil
    var bars: Int? = nil   // nil = a section found by silence
    var score: Double      // 0...1, how well the end flows back into the start (higher = more seamless)
}

enum ZeroCrossing {
    /// Index of the rising zero crossing nearest to `index` (within `radius` samples); `index` itself if there is none.
    static func nearest(in s: [Float], to index: Int, radius: Int) -> Int {
        var best: Int?
        let lo = max(1, index - radius), hi = min(s.count - 1, index + radius)
        guard lo <= hi else { return index }
        for i in lo...hi where s[i - 1] < 0 && s[i] >= 0 {
            if best == nil || abs(i - index) < abs(best! - index) { best = i }
        }
        return best ?? index
    }

    /// Time (s) of the nearest rising zero crossing around `time`, read from the file; unchanged if none within 10 ms.
    static func nearestTime(url: URL, to time: Double) async -> Double {
        await Task.detached {
            guard let f = try? AVAudioFile(forReading: url) else { return time }
            let sr = f.processingFormat.sampleRate, r = Int(0.01 * sr)
            let center = Int(time * sr), from = max(0, center - r)
            let count = min(2 * r + 1, Int(f.length) - from)
            guard count > 2, let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(count)) else { return time }
            f.framePosition = AVAudioFramePosition(from)
            guard (try? f.read(into: buf, frameCount: AVAudioFrameCount(count))) != nil, let ch = buf.floatChannelData?[0] else { return time }
            let s = Array(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
            return Double(from + nearest(in: s, to: center - from, radius: r)) / sr
        }.value
    }
}

enum LoopDetector {
    /// shortcut: analyses only the first 5 minutes (keeps memory at ~50 MB); raise if long mixes need loop suggestions.
    static let maxSeconds = 300.0

    static func candidates(url: URL) async throws -> [LoopCandidate] {
        try await Task.detached {
            let file = try AVAudioFile(forReading: url)
            let sr = file.processingFormat.sampleRate
            let total = min(Int(file.length), Int(maxSeconds * sr))
            guard total > 0, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16384) else { return [] }
            var mono = [Float](); mono.reserveCapacity(total)
            let channels = Int(file.processingFormat.channelCount)
            while mono.count < total {
                try file.read(into: buf, frameCount: 16384)
                let n = min(Int(buf.frameLength), total - mono.count)
                if n == 0 { break }
                for i in 0..<n {
                    var v: Float = 0
                    for c in 0..<channels { v += buf.floatChannelData![c][i] }
                    mono.append(v / Float(channels))
                }
            }
            return analyze(samples: mono, sampleRate: sr)
        }.value
    }

    /// Pure analysis (testable without files): tempo-based bar loops first, then sections between silences.
    static func analyze(samples: [Float], sampleRate sr: Double) -> [LoopCandidate] {
        let hop = 512, n = samples.count / hop
        guard n > 8 else { return [] }
        var env = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var sum: Float = 0
            for j in (i * hop)..<((i + 1) * hop) { sum += samples[j] * samples[j] }
            env[i] = (sum / Float(hop)).squareRoot()
        }
        guard let peak = env.max(), peak > 0.002 else { return [] }  // silence
        let hopSec = Double(hop) / sr
        return tempoCandidates(samples, env, hop, sr, hopSec) + sectionCandidates(samples, env, peak, hop, sr, hopSec)
    }

    // MARK: tempo

    private static func tempoCandidates(_ s: [Float], _ env: [Float], _ hop: Int, _ sr: Double, _ hopSec: Double) -> [LoopCandidate] {
        let n = env.count
        var onset = [Float](repeating: 0, count: n)
        onset[0] = env[0]
        for i in 1..<n { onset[i] = max(0, env[i] - env[i - 1]) }

        func at(_ x: Double) -> Float {  // linear interpolation
            let i = Int(x), f = Float(x - Double(i))
            return i + 1 < n ? onset[i] * (1 - f) + onset[i + 1] * f : 0
        }
        func acr(_ lag: Double) -> Float {
            var sum: Float = 0, c = 0
            var i = 0
            while Double(i) + lag < Double(n - 1) { sum += onset[i] * at(Double(i) + lag); c += 1; i += 1 }
            return c > 0 ? sum / Float(c) : 0
        }
        let zero = acr(0)
        guard zero > 0 else { return [] }
        var bestBPM = 0.0, bestScore: Float = 0
        for bpm in stride(from: 70.0, through: 170.0, by: 0.25) {
            let lag = 60 / bpm / hopSec
            guard lag * 8 < Double(n) else { continue }  // need a few beats to judge
            let sc = acr(lag) + 0.5 * acr(2 * lag)
            if sc > bestScore { bestScore = sc; bestBPM = bpm }
        }
        guard bestBPM > 0, bestScore > 0.3 * zero else { return [] }  // not rhythmic

        let beat = 60 / bestBPM / hopSec  // hops per beat
        var phase = 0, phaseScore: Float = -1
        for p in 0..<Int(beat.rounded(.up)) {
            var sum: Float = 0, k = 0
            while Int((Double(p) + Double(k) * beat).rounded()) < n { sum += onset[Int((Double(p) + Double(k) * beat).rounded())]; k += 1 }
            if sum > phaseScore { phaseScore = sum; phase = p }
        }
        func snapOnset(_ h: Double) -> Double {  // nearest strong onset within 2 hops
            let c = Int(h.rounded()); var best = c
            for i in max(0, c - 2)...min(n - 1, c + 2) where onset[i] > onset[best] { best = i }
            return Double(best)
        }
        let startHop = snapOnset(Double(phase))
        let w = Int(0.04 * sr)
        var out: [LoopCandidate] = []
        for bars in [1, 2, 4, 8] {
            let endHop = snapOnset(startHop + Double(bars * 4) * beat)
            var a = Int(startHop * Double(hop)), b = Int(endHop * Double(hop))
            guard b + w <= s.count, b > a else { continue }
            a = ZeroCrossing.nearest(in: s, to: a, radius: Int(0.005 * sr))
            b = ZeroCrossing.nearest(in: s, to: b, radius: Int(0.005 * sr))
            let sim = similarity(s, a, b, w)
            let st = Double(a) / sr, en = Double(b) / sr
            out.append(LoopCandidate(title: "\(bars) \(bars == 1 ? "bar" : "bars") · \(Int(bestBPM.rounded())) BPM",
                                     detail: "\(clock(st))–\(clock(en)) · seamless \(Int(sim * 100)) %",
                                     start: st, end: en, bpm: bestBPM, bars: bars, score: sim))
        }
        return out
    }

    /// 0...1: how much the audio right after `b` (where a loop would jump back from) resembles the audio at `a`.
    private static func similarity(_ s: [Float], _ a: Int, _ b: Int, _ w: Int) -> Double {
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<w { dot += s[a + i] * s[b + i]; na += s[a + i] * s[a + i]; nb += s[b + i] * s[b + i] }
        let d = (na * nb).squareRoot()
        return d > 0 ? Double((dot / d + 1) / 2) : 0
    }

    // MARK: sections

    private static func sectionCandidates(_ s: [Float], _ env: [Float], _ peak: Float, _ hop: Int, _ sr: Double, _ hopSec: Double) -> [LoopCandidate] {
        let thr = max(0.05 * peak, 0.002), maxGap = Int(0.25 / hopSec), minLen = Int(0.4 / hopSec)
        var regions: [(Int, Int)] = []
        for (i, e) in env.enumerated() where e > thr {
            if let last = regions.last, i - last.1 <= maxGap + 1 { regions[regions.count - 1].1 = i } else { regions.append((i, i)) }
        }
        regions = regions.filter { $0.1 - $0.0 + 1 >= minLen }
        guard regions.count >= 2 else { return [] }  // one region is just "the whole file"
        let w = Int(0.04 * sr)
        return regions.prefix(8).enumerated().map { k, r in
            var a = r.0 * hop, b = min((r.1 + 1) * hop, s.count - 1)
            a = ZeroCrossing.nearest(in: s, to: a, radius: Int(0.005 * sr))
            b = ZeroCrossing.nearest(in: s, to: b, radius: Int(0.005 * sr))
            let st = Double(a) / sr, en = Double(b) / sr
            let sim = b + w <= s.count ? similarity(s, a, b, w) : 0
            return LoopCandidate(title: "Section \(k + 1)", detail: "\(clock(st))–\(clock(en)) · \(String(format: "%.1f", en - st)) s",
                                 start: st, end: en, score: sim)
        }
    }

    static func clock(_ t: Double) -> String {
        let m = Int(t) / 60
        return String(format: "%d:%05.2f", m, t - Double(m * 60))
    }
}
