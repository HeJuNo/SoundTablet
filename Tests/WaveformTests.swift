import Foundation
import Testing
@testable import SoundTablet

@Suite struct WaveformTests {
    @Test func tonePeaksNearHalf() async throws {
        let peaks = try await waveformPeaks(url: try makeTone(), buckets: 10)
        #expect(peaks.allSatisfy { $0 > 0.45 && $0 <= 0.5 + 0.01 })
    }
    @Test func silenceIsZero() async throws {
        let peaks = try await waveformPeaks(url: try makeTone(seconds: 0.5, amplitude: 0), buckets: 4)
        #expect(peaks.allSatisfy { $0 == 0 })
    }
    @Test func bucketCountMatches() async throws {
        #expect(try await waveformPeaks(url: try makeTone(), buckets: 37).count == 37)
    }
}
