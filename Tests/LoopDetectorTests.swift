import Foundation
import Testing
@testable import SoundTablet

struct LoopDetectorTests {
    let sr = 44100.0

    /// Decaying 1 kHz click every `beat` seconds.
    func clickTrack(bpm: Double, seconds: Double) -> [Float] {
        var s = [Float](repeating: 0, count: Int(seconds * sr))
        let beat = 60 / bpm
        var t = 0.0
        while t < seconds - 0.05 {
            let i0 = Int(t * sr)
            for k in 0..<Int(0.03 * sr) where i0 + k < s.count {
                s[i0 + k] = 0.9 * sinf(2 * .pi * 1000 * Float(k) / Float(sr)) * expf(-Float(k) / Float(0.008 * sr))
            }
            t += beat
        }
        return s
    }

    func bursts(starts: [Double], length: Double, total: Double) -> [Float] {
        var s = [Float](repeating: 0, count: Int(total * sr))
        for st in starts { for k in 0..<Int(length * sr) { s[Int(st * sr) + k] = 0.5 * sinf(2 * .pi * 440 * Float(k) / Float(sr)) } }
        return s
    }

    @Test func detectsTempoAndOffersBarLengthLoops() throws {
        let c = LoopDetector.analyze(samples: clickTrack(bpm: 120, seconds: 17), sampleRate: sr)
        let twoBars = try #require(c.first { $0.bars == 2 })
        #expect(abs((twoBars.bpm ?? 0) - 120) < 1.5)
        #expect(abs(twoBars.start - 0) < 0.03)
        #expect(abs(twoBars.end - 4.0) < 0.03)   // 2 bars x 4 beats x 0.5 s
        #expect(c.contains { $0.bars == 1 } && c.contains { $0.bars == 4 })
    }

    @Test func splitsAtSilenceIntoSections() {
        let c = LoopDetector.analyze(samples: bursts(starts: [0.5, 2.5, 4.5], length: 1, total: 6), sampleRate: sr)
        let sections = c.filter { $0.bars == nil }.sorted { $0.start < $1.start }
        #expect(sections.count == 3)
        #expect(abs(sections[1].start - 2.5) < 0.03 && abs(sections[1].end - 3.5) < 0.03)
    }

    @Test func silenceYieldsNothing() {
        #expect(LoopDetector.analyze(samples: [Float](repeating: 0, count: 44100 * 3), sampleRate: sr).isEmpty)
    }

    @Test func zeroCrossingSnapsToNearestRisingCrossing() {
        // sine at 100 Hz: rising crossings every 10 ms (441 samples)
        let s = (0..<44100).map { sinf(2 * .pi * 100 * Float($0) / 44100) }
        let i = ZeroCrossing.nearest(in: s, to: 1000, radius: 441)
        #expect(abs(i - 882) <= 1 || abs(i - 1323) <= 1)
        #expect(i != 1000)
    }
}
