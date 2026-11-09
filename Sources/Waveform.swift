import AVFoundation

/// Peak amplitude (0...1) per bucket, streamed in chunks so long files never load fully into memory.
func waveformPeaks(url: URL, buckets: Int) async throws -> [Float] {
    try await Task.detached {
        let file = try AVAudioFile(forReading: url)
        var peaks = [Float](repeating: 0, count: max(buckets, 0))
        let total = Int(file.length)
        guard total > 0, buckets > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16384) else { return peaks }
        var done = 0
        while done < total {
            try file.read(into: buf, frameCount: 16384)
            let n = Int(buf.frameLength)
            if n == 0 { break }
            for c in 0..<Int(file.processingFormat.channelCount) {
                let ch = buf.floatChannelData![c]
                for i in 0..<n {
                    let b = min(buckets - 1, (done + i) * buckets / total)
                    peaks[b] = max(peaks[b], abs(ch[i]))
                }
            }
            done += n
        }
        return peaks
    }.value
}
