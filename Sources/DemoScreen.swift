import Foundation

/// Debug-only launch states for the screenshot script (`-demoScreen editor|suggestions|settings|defaults`).
/// Compiled out of release builds.
import AVFoundation

enum DemoScreen {
    static var current: String? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "demoScreen")
        #else
        nil
        #endif
    }

    /// Debug only (`-seedDemo YES`): a fresh board with a few tracks (replaces existing boards), so UI tests and screenshots have tiles to look at.
    @MainActor static func seedIfRequested(_ model: AppModel) async {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "seedDemo") else { return }
        for b in model.boards { try? await model.store.deleteBoard(b.id) }  // always start from the same board
        model.boards = []
        await model.addBoard(name: "Show")
        var urls: [URL] = []
        for hz in [220.0, 330, 440, 550, 660, 770] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(Int(hz)) Hz.wav")
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44100 * 2)!
            buf.frameLength = 44100 * 2
            for i in 0..<Int(buf.frameLength) { buf.floatChannelData![0][i] = 0.3 * sinf(2 * .pi * Float(hz) * Float(i) / 44100) }
            try? AVAudioFile(forWriting: url, settings: fmt.settings).write(from: buf)
            urls.append(url)
        }
        await model.importTracks(urls)
        #endif
    }
}
