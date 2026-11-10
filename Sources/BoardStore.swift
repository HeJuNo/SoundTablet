import Foundation

protocol BoardStore: Sendable {
    func loadBoards() async throws -> [Board]
    func save(_ board: Board) async throws
    func deleteBoard(_ id: Board.ID) async throws
    /// Copies the file into the board's folder; returns the stored file name.
    func importAudio(from url: URL, into board: Board.ID, as track: Track.ID) async throws -> String
    /// nil when the file is missing (or, for iCloud, not downloaded yet).
    func audioURL(board: Board.ID, fileName: String) async throws -> URL?
    func deleteFile(board: Board.ID, fileName: String) async throws
}

func sanitizedFolderName(_ s: String) -> String {
    var t = s.filter { $0 != "/" && $0 != ":" && $0 != "\0" }
        .trimmingCharacters(in: .whitespacesAndNewlines)
    while t.hasPrefix(".") { t.removeFirst() }
    t = t.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? "Untitled" : t
}

struct LocalBoardStore: BoardStore {
    let root: URL
    init(root: URL) { self.root = root }

    private var fm: FileManager { .default }

    /// shortcut: scans every board.json per lookup, fine for tens of boards; index if it ever lags.
    private func folders() throws -> [(url: URL, board: Board)] {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("board.json")),
                  let b = try? JSONDecoder().decode(Board.self, from: data) else { return nil }
            return (dir, b)
        }
    }

    private func folder(for id: Board.ID) throws -> URL? {
        try folders().first { $0.board.id == id }?.url
    }

    func loadBoards() async throws -> [Board] {
        try folders().map(\.board).sorted { ($0.sortIndex, $0.name) < ($1.sortIndex, $1.name) }
    }

    func save(_ board: Board) async throws {
        let dir: URL
        if let existing = try folder(for: board.id) {
            dir = existing
        } else {
            let base = sanitizedFolderName(board.name)
            var candidate = root.appendingPathComponent(base), n = 2
            while fm.fileExists(atPath: candidate.path) {
                candidate = root.appendingPathComponent("\(base) \(n)"); n += 1
            }
            try fm.createDirectory(at: candidate, withIntermediateDirectories: true)
            dir = candidate
        }
        try JSONEncoder().encode(board).write(to: dir.appendingPathComponent("board.json"), options: .atomic)
    }

    func deleteBoard(_ id: Board.ID) async throws {
        if let dir = try folder(for: id) { try fm.removeItem(at: dir); SyncService.markDeleted(dir.lastPathComponent, in: root) }
    }

    func importAudio(from url: URL, into board: Board.ID, as track: Track.ID) async throws -> String {
        guard let dir = try folder(for: board) else { throw CocoaError(.fileNoSuchFile) }
        let ext = url.pathExtension.isEmpty ? "audio" : url.pathExtension
        let name = "\(track.uuidString).\(ext)"
        let dest = dir.appendingPathComponent(name)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: url, to: dest)
        return name
    }

    func audioURL(board: Board.ID, fileName: String) async throws -> URL? {
        guard let dir = try folder(for: board) else { return nil }
        let url = dir.appendingPathComponent(fileName)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    func deleteFile(board: Board.ID, fileName: String) async throws {
        guard let dir = try folder(for: board) else { return }
        try? fm.removeItem(at: dir.appendingPathComponent(fileName))
    }
}
