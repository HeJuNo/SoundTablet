import Foundation

/// Reads the folder of the "Soundboard Studio" app (soundboard.json + the audio files beside it) and maps its boards and
/// buttons to ours. Not carried over: pan (never used), play history, backups, "animates".
enum SoundboardStudioImport {
    struct Result {
        var boards: [Board] = []             // tracks still carry the original file name; see `sources`
        var sources: [Track.ID: URL] = [:]   // audio file of every track
        var skipped: [String] = []           // titles of buttons whose audio file is missing
    }

    private struct File: Decodable { var boards: [String: B]; var tracks: [String: T] }
    private struct B: Decodable { var title: String; var colorScheme: String; var order: Int }
    private struct T: Decodable {
        var title: String, file: String, board: String, colorScheme: String, order: Int
        var volume: Float, loops: Bool, solo: Bool, fadesIn: Bool, fadesOut: Bool, playsNext: Bool
        var fadesInDuration: Double, fadesOutDuration: Double, trimInPoint: Double, trimOutPoint: Double, fullDuration: Double
    }

    private static let colors = ["red": 0, "orange": 1, "yellow": 2, "green": 3, "blue": 4, "purple": 5, "pink": 6]
    static func hex(_ scheme: String) -> String { tilePalette[colors[scheme] ?? 7] }  // white, black, unknown -> grey

    static func read(_ folder: URL) throws -> Result {
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: folder.appendingPathComponent("soundboard.json")))
        // The app writes decomposed accents (NFD), the file system may hand them back composed: match both.
        let onDisk = Dictionary(try FileManager.default.contentsOfDirectory(atPath: folder.path).map { ($0.precomposedStringWithCanonicalMapping, $0) },
                                uniquingKeysWith: { a, _ in a })
        var r = Result()
        for (bid, b) in file.boards.sorted(by: { $0.value.order < $1.value.order }) {
            var board = Board(id: UUID(), name: b.title, colorHex: hex(b.colorScheme), sortIndex: b.order)
            let mine = file.tracks.values.filter { $0.board == bid }.sorted { $0.order < $1.order }
            var tracks: [(Track, playsNext: Bool)] = []
            for t in mine {
                guard let name = onDisk[t.file.precomposedStringWithCanonicalMapping] else { r.skipped.append(t.title); continue }
                var s = TrackSettings()
                s.volume = t.volume; s.loop = t.loops; s.solo = t.solo
                s.fadeIn = t.fadesIn ? t.fadesInDuration : 0
                s.fadeOut = t.fadesOut ? t.fadesOutDuration : 0
                s.trimIn = t.trimInPoint
                s.trimOut = t.trimOutPoint < t.fullDuration - 0.05 ? t.trimOutPoint : nil
                let track = Track(id: UUID(), name: t.title.precomposedStringWithCanonicalMapping, fileName: name, colorHex: hex(t.colorScheme), settings: s)
                r.sources[track.id] = folder.appendingPathComponent(name)
                tracks.append((track, t.playsNext))
            }
            // "plays next" = when this button ends, the next one on the board starts
            for i in tracks.indices where tracks[i].playsNext && i + 1 < tracks.count {
                tracks[i].0.automations = [Automation(trigger: .ended, action: .play, target: tracks[i + 1].0.id)]
            }
            board.tracks = tracks.map(\.0)
            r.boards.append(board)
        }
        return r
    }
}
