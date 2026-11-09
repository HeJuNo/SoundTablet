import AVFoundation

/// RMS level of the whole file in dBFS (all channels), streamed so long files never load fully.
/// shortcut: plain RMS, no K-weighting or gating like LUFS; upgrade if quiet passages skew the match.
func loudnessDB(url: URL) async throws -> Double {
    try await Task.detached {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16384) else { return -120 }
        var sum = 0.0, count = 0.0
        while file.framePosition < file.length {
            try file.read(into: buf, frameCount: 16384)
            let n = Int(buf.frameLength)
            if n == 0 { break }
            for c in 0..<Int(file.processingFormat.channelCount) {
                let ch = buf.floatChannelData![c]
                for i in 0..<n { sum += Double(ch[i] * ch[i]) }
            }
            count += Double(n) * Double(file.processingFormat.channelCount)
        }
        return count > 0 && sum > 0 ? 10 * log10(sum / count) : -120
    }.value
}

/// Linear gain that brings a track down to the reference level. Never above 1: player-node volume tops out at 1,
/// so tracks quieter than the reference stay unchanged (shortcut: no boost; add an EQ gain stage if that is needed).
func normalizationGain(trackDB: Double, referenceDB: Double) -> Float {
    min(1, Float(pow(10, (referenceDB - trackDB) / 20)))
}
