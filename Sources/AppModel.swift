import Foundation
import Observation
import SwiftUI
import UIKit

let tilePalette = ["#E5484D", "#F76B15", "#F5B800", "#30A46C", "#0091FF", "#6E56CF", "#D6409F", "#8D8D8D"]

extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

struct SyncConfig: Sendable {
    var local: URL
    var cloud: @Sendable () -> URL?
}

@MainActor @Observable final class AppModel {
    var boards: [Board] = []
    var activeBoardID: Board.ID?
    private(set) var playing: Set<Track.ID> = []
    private(set) var unavailable: Set<Track.ID> = []
    var isPaused = false
    /// Buttons paused by a tap (voice kept, resumes on the next tap).
    private(set) var paused: Set<Track.ID> = []
    @ObservationIgnored var doubleTapWindow: Duration = .milliseconds(400)
    @ObservationIgnored private var lastResume: (id: Track.ID, at: ContinuousClock.Instant)?
    /// Settings applied to every newly imported track; persisted in UserDefaults.
    var defaults: TrackSettings = .default {
        didSet { userDefaults.set(try? JSONEncoder().encode(defaults), forKey: "defaultTrackSettings") }
    }
    /// Smallest width of a button tile in points; the grid fits as many columns as the screen allows.
    static let tileWidthRange: ClosedRange<Double> = 90...260
    var tileMinWidth: Double = 150 {
        didSet {
            let c = min(max(tileMinWidth, Self.tileWidthRange.lowerBound), Self.tileWidthRange.upperBound)
            if c != tileMinWidth { tileMinWidth = c; return }
            userDefaults.set(tileMinWidth, forKey: "tileMinWidth")
        }
    }
    var transportStyle: TransportStyle = .toolbar {
        didSet { userDefaults.set(transportStyle.rawValue, forKey: "transportStyle") }
    }
    /// Loudness (dBFS) of the reference file chosen in Defaults; persisted in UserDefaults.
    private(set) var referenceDB: Double?
    private(set) var referenceName: String?
    var lastError: String?
    var editingTrackID: Track.ID?
    var editingBoardID: Board.ID?
    private(set) var syncStatus = "Not synced yet"
    private(set) var isSyncing = false
    var showingDefaults = false

    @ObservationIgnored let store: BoardStore
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let syncConfig: SyncConfig?
    @ObservationIgnored private(set) var engine: AudioEngine!
    @ObservationIgnored private let automation = AutomationEngine()

    init(store: BoardStore, manualRendering: Bool = false, userDefaults: UserDefaults = .standard, sync: SyncConfig? = nil) {
        self.store = store
        self.syncConfig = sync
        self.userDefaults = userDefaults
        if let d = userDefaults.data(forKey: "defaultTrackSettings"), let v = try? JSONDecoder().decode(TrackSettings.self, from: d) {
            defaults = v
        }
        engine = AudioEngine(onEvent: { [weak self] in self?.handle($0) }, manualRendering: manualRendering)
        if userDefaults.object(forKey: "tileMinWidth") != nil { tileMinWidth = userDefaults.double(forKey: "tileMinWidth") }
        if let t = userDefaults.string(forKey: "transportStyle").flatMap(TransportStyle.init(rawValue:)) { transportStyle = t }
        if let r = userDefaults.object(forKey: "referenceDB") as? Double {
            referenceDB = r; referenceName = userDefaults.string(forKey: "referenceName"); engine.referenceDB = r
        }
    }

    var activeBoard: Board? { boards.first { $0.id == activeBoardID } }

    // MARK: loading / persistence

    func load() async {
        do { boards = try await store.loadBoards() } catch { lastError = error.localizedDescription }
        if activeBoard == nil { activeBoardID = boards.first?.id }
        for b in boards { for t in b.tracks { await register(t, in: b.id) } }
    }

    private func register(_ t: Track, in board: Board.ID) async {
        if let url = try? await store.audioURL(board: board, fileName: t.fileName), (try? engine.load(t, url: url)) != nil {
            unavailable.remove(t.id)
        } else {
            unavailable.insert(t.id)
        }
    }

    private func persist(_ id: Board.ID) async {
        guard let b = boards.first(where: { $0.id == id }) else { return }
        do { try await store.save(b) } catch { lastError = error.localizedDescription }
    }

    func boardID(of track: Track.ID) -> Board.ID? {
        boards.first { $0.tracks.contains { $0.id == track } }?.id
    }

    // MARK: editing

    func addBoard(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = Board(id: UUID(), name: trimmed.isEmpty ? "Board \(boards.count + 1)" : trimmed, colorHex: tilePalette[boards.count % tilePalette.count], sortIndex: boards.count)
        boards.append(b)
        activeBoardID = b.id
        await persist(b.id)
    }

    /// Renames / recolours a board. A blank name keeps the old one, so a title can never disappear.
    func updateBoard(_ id: Board.ID, name: String, colorHex: String) async {
        guard let i = boards.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { boards[i].name = trimmed }
        boards[i].colorHex = colorHex
        await persist(id)
    }

    func deleteBoard(_ id: Board.ID) async {
        guard let i = boards.firstIndex(where: { $0.id == id }) else { return }
        for t in boards[i].tracks { engine.stop(t.id) }
        do { try await store.deleteBoard(id) } catch { lastError = error.localizedDescription; return }
        boards.remove(at: i)
        for j in boards.indices { boards[j].sortIndex = j }
        if activeBoardID == id { activeBoardID = boards.first?.id }
        for b in boards { await persist(b.id) }
    }

    /// Imports every board of a Soundboard Studio folder as new boards behind the existing ones; returns a one-line summary.
    /// Running it twice imports everything twice.
    func importSoundboardStudio(_ folder: URL) async -> String {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let r: SoundboardStudioImport.Result
        do { r = try SoundboardStudioImport.read(folder) } catch { return "Not a Soundboard Studio folder: \(error.localizedDescription)" }
        var buttons = 0, failed = 0
        let offset = boards.count
        for var b in r.boards {
            let tracks = b.tracks
            b.tracks = []; b.sortIndex += offset
            boards.append(b)
            await persist(b.id)
            for var t in tracks {
                do { t.fileName = try await store.importAudio(from: r.sources[t.id]!, into: b.id, as: t.id) } catch { failed += 1; continue }
                guard let i = boards.firstIndex(where: { $0.id == b.id }) else { break }
                boards[i].tracks.append(t); buttons += 1
                await register(t, in: b.id)
            }
            await persist(b.id)
        }
        activeBoardID = boards.count > offset ? boards[offset].id : activeBoardID
        return "Imported \(r.boards.count) boards, \(buttons) buttons"
            + (r.skipped.isEmpty && failed == 0 ? "" : "; \(r.skipped.count + failed) skipped (audio file missing or unreadable)")
    }

    func importTracks(_ urls: [URL]) async {
        guard let bid = activeBoardID else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let tid = UUID()
            do {
                let file = try await store.importAudio(from: url, into: bid, as: tid)
                guard let i = boards.firstIndex(where: { $0.id == bid }) else { return }
                var t = Track(id: tid, name: url.deletingPathExtension().lastPathComponent, fileName: file,
                              colorHex: tilePalette[boards[i].tracks.count % tilePalette.count])
                t.settings = defaults
                boards[i].tracks.append(t)
                await persist(bid)
                await register(t, in: bid)
            } catch { lastError = "\(url.lastPathComponent): \(error.localizedDescription)" }
        }
    }

    /// New buttons that play parts of an existing track's audio file (no copy of the file): each gets its own
    /// trim and loops by default. Returns the new track ids, inserted right after the source button.
    @discardableResult
    func addExcerpts(from id: Track.ID, _ items: [(name: String, subtitle: String?, start: Double, end: Double)]) async -> [Track.ID] {
        guard let src = track(id), let bid = boardID(of: id), let bi = boards.firstIndex(where: { $0.id == bid }),
              var at = boards[bi].tracks.firstIndex(where: { $0.id == id }) else { return [] }
        var made: [Track] = []
        for it in items {
            var t = Track(id: UUID(), name: it.name, subtitle: it.subtitle, fileName: src.fileName, colorHex: src.colorHex)
            t.settings = src.settings
            t.settings.trimIn = it.start; t.settings.trimOut = it.end; t.settings.loop = true
            at += 1
            boards[bi].tracks.insert(t, at: at)
            made.append(t)
        }
        await persist(bid)
        for t in made { await register(t, in: bid) }
        return made.map(\.id)
    }

    // MARK: audition (suggestions / editor): plays a range of a track's file without touching the track

    @ObservationIgnored private let previewID = UUID()

    func preview(_ id: Track.ID, start: Double, end: Double) async {
        guard let src = track(id), let url = await audioURL(for: id) else { return }
        engine.stop(previewID)
        var p = Track(id: previewID, name: "Preview", fileName: src.fileName, colorHex: src.colorHex)
        p.settings = src.settings
        p.settings.trimIn = start; p.settings.trimOut = end
        p.settings.loop = true; p.settings.solo = false; p.settings.fadeIn = 0; p.settings.fadeOut = 0
        guard (try? engine.load(p, url: url)) != nil else { return }
        engine.play(previewID)
    }

    func stopPreview() { engine.stop(previewID); engine.unload(previewID) }

    func track(_ id: Track.ID) -> Track? { boards.lazy.flatMap(\.tracks).first { $0.id == id } }

    /// In-memory replace; returns the board id. Synchronous so UI bindings never see stale values.
    private func apply(_ track: Track) -> Board.ID? {
        guard let bid = boardID(of: track.id), let bi = boards.firstIndex(where: { $0.id == bid }),
              let ti = boards[bi].tracks.firstIndex(where: { $0.id == track.id }) else { return nil }
        boards[bi].tracks[ti] = track
        return bid
    }

    /// Persist + re-register the *current* state (not a captured copy), so racing edits end consistent.
    private func settle(_ id: Track.ID, _ bid: Board.ID) async {
        await persist(bid)
        if let t = track(id) { await register(t, in: bid) }
    }

    func update(_ track: Track) async {
        guard let bid = apply(track) else { return }
        await settle(track.id, bid)
    }

    /// Synchronous edit for bindings; saving happens in the background.
    func edit(_ id: Track.ID, _ change: (inout Track) -> Void) {
        guard var t = track(id) else { return }
        change(&t)
        guard let bid = apply(t) else { return }
        Task { await settle(id, bid) }
    }

    /// Measures the chosen file and keeps only its loudness (the file itself is not stored).
    func setReference(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let db = try await loudnessDB(url: url)
            referenceDB = db; referenceName = url.lastPathComponent; engine.referenceDB = db
            userDefaults.set(db, forKey: "referenceDB"); userDefaults.set(url.lastPathComponent, forKey: "referenceName")
        } catch { lastError = error.localizedDescription }
    }

    func clearReference() {
        referenceDB = nil; referenceName = nil; engine.referenceDB = nil
        userDefaults.removeObject(forKey: "referenceDB"); userDefaults.removeObject(forKey: "referenceName")
    }

    /// Turning on measures the track once (cached in its settings); applies from the next play.
    func setNormalize(_ id: Track.ID, _ on: Bool) async {
        guard var t = track(id) else { return }
        if on, t.settings.loudnessDB == nil {
            guard let url = await audioURL(for: id), let db = try? await loudnessDB(url: url) else {
                lastError = "Could not measure this track's loudness"; return
            }
            t.settings.loudnessDB = db
        }
        t.settings.normalize = on
        await update(t)
    }

    func normalizeAll(_ on: Bool) async {
        for id in boards.flatMap(\.tracks).map(\.id) { await setNormalize(id, on) }
    }

    func audioURL(for id: Track.ID, imageFile: Bool = false) async -> URL? {
        guard let bid = boardID(of: id), let t = track(id), let name = imageFile ? t.imageFileName : t.fileName else { return nil }
        return try? await store.audioURL(board: bid, fileName: name)
    }

    /// Stores a 300 px JPEG thumbnail next to the audio; nil removes the image reference (file stays, see deleteTrack shortcut).
    func setImage(_ id: Track.ID, data: Data?) async {
        guard let bid = boardID(of: id) else { return }
        var name: String? = nil
        if let data, let img = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 300, height: 300)),
           let jpeg = img.jpegData(compressionQuality: 0.8) {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
            defer { try? FileManager.default.removeItem(at: tmp) }
            do {
                try jpeg.write(to: tmp)
                name = try await store.importAudio(from: tmp, into: bid, as: UUID())
            } catch { lastError = error.localizedDescription; return }
        }
        guard var t = track(id) else { return }
        t.imageFileName = name
        await update(t)
    }

    /// Clamps to the file: out before/at in or past the end means "to the end"; in is kept inside the file.
    func setTrim(_ id: Track.ID, trimIn: Double, trimOut: Double?) async {
        guard let duration = engine.duration(id), var t = boards.flatMap(\.tracks).first(where: { $0.id == id }) else { return }
        let i = min(max(trimIn, 0), max(duration - 0.05, 0))
        t.settings.trimIn = i
        t.settings.trimOut = trimOut.flatMap { $0 > i && $0 < duration ? $0 : nil }
        await update(t)
    }

    /// Rejects self-targets and targets that are not on the same board.
    func addAutomation(to id: Track.ID, _ a: Automation) async {
        guard let bid = boardID(of: id), a.target != id, boardID(of: a.target) == bid,
              var t = boards.flatMap(\.tracks).first(where: { $0.id == id }) else { return }
        t.automations.append(a)
        await update(t)
    }

    func removeAutomation(from id: Track.ID, at index: Int) async {
        guard var t = boards.flatMap(\.tracks).first(where: { $0.id == id }), t.automations.indices.contains(index) else { return }
        t.automations.remove(at: index)
        await update(t)
    }

    /// shortcut: the audio file stays in the board folder (no store API to delete it); add one if disk use matters.
    func deleteTrack(_ id: Track.ID) async {
        guard let bid = boardID(of: id), let bi = boards.firstIndex(where: { $0.id == bid }) else { return }
        engine.stop(id)
        engine.unload(id)
        unavailable.remove(id)
        boards[bi].tracks.removeAll { $0.id == id }
        for ti in boards[bi].tracks.indices { boards[bi].tracks[ti].automations.removeAll { $0.target == id } }
        await persist(bid)
    }

    func moveTrack(_ id: Track.ID, before target: Track.ID) async {
        guard id != target, let bid = boardID(of: id), bid == boardID(of: target),
              let bi = boards.firstIndex(where: { $0.id == bid }),
              let from = boards[bi].tracks.firstIndex(where: { $0.id == id }) else { return }
        let t = boards[bi].tracks.remove(at: from)
        let to = boards[bi].tracks.firstIndex(where: { $0.id == target }) ?? boards[bi].tracks.endIndex
        boards[bi].tracks.insert(t, at: to)
        await persist(bid)
    }

    /// Moves a button to another board: files are copied first and the originals removed only after both boards are saved.
    func moveTrack(_ id: Track.ID, toBoard target: Board.ID) async {
        guard let src = boardID(of: id), src != target, boards.contains(where: { $0.id == target }), var t = track(id) else { return }
        engine.stop(id)
        var old: [String] = []
        do {
            if let url = try await store.audioURL(board: src, fileName: t.fileName) {
                old.append(t.fileName)
                t.fileName = try await store.importAudio(from: url, into: target, as: id)
            }
            if let img = t.imageFileName, let url = try await store.audioURL(board: src, fileName: img) {
                old.append(img)
                t.imageFileName = try await store.importAudio(from: url, into: target, as: UUID())
            }
        } catch { lastError = error.localizedDescription; return }
        boards[boards.firstIndex { $0.id == src }!].tracks.removeAll { $0.id == id }
        boards[boards.firstIndex { $0.id == target }!].tracks.append(t)
        await persist(target)   // target first: a crash in between leaves a duplicate, never a loss
        await persist(src)
        for f in old { try? await store.deleteFile(board: src, fileName: f) }
        await register(t, in: target)
    }

    func moveBoard(_ id: Board.ID, before target: Board.ID) async {
        guard id != target, let from = boards.firstIndex(where: { $0.id == id }) else { return }
        let b = boards.remove(at: from)
        boards.insert(b, at: boards.firstIndex(where: { $0.id == target }) ?? boards.endIndex)
        for i in boards.indices { boards[i].sortIndex = i }
        for b in boards { await persist(b.id) }
    }

    // MARK: sync

    /// Mirrors the local store with iCloud Drive off the main thread; playback and editing never wait for it.
    func syncNow() async {
        guard let cfg = syncConfig, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let result: Result<SyncReport, Error>? = await Task.detached {
            guard let cloud = cfg.cloud() else { return nil }
            return Result { try SyncService(local: cfg.local, cloud: cloud).sync() }
        }.value
        switch result {
        case nil: syncStatus = "iCloud not available"
        case .failure(let e): syncStatus = "Sync failed: \(e.localizedDescription)"
        case .success(let r):
            syncStatus = "Synced \(Date.now.formatted(date: .omitted, time: .shortened)): \(r.copiedToCloud) up, \(r.copiedToLocal) down"
                + (r.removed == 0 ? "" : ", \(r.removed) removed")
                + (r.conflicts.isEmpty ? "" : ", \(r.conflicts.count) conflict(s) kept as copies")
                + (r.errors.isEmpty ? "" : ", \(r.errors.count) file(s) failed")
                + (r.pendingDownloads > 0 ? ", \(r.pendingDownloads) still downloading" : "")
            // Always reload after files came down: a stale in-memory board must never be persisted over them.
            // load() only replaces boards/engine registrations; running voices and `playing` are keyed by id.
            if r.copiedToLocal > 0 || r.removed > 0 { await load() }
        }
    }

    // MARK: playback

    /// Tap on a playing button pauses it; the next tap continues there, a quick second tap restarts from the beginning.
    /// Pressing any other button drops all paused buttons.
    func tap(_ id: Track.ID) {
        guard !unavailable.contains(id) else { return }
        for other in paused where other != id { engine.release(other) }
        paused = paused.filter { $0 == id }
        let now = ContinuousClock.now
        if playing.contains(id) {
            if let r = lastResume, r.id == id, now - r.at < doubleTapWindow { lastResume = nil; engine.play(id); return }
            engine.pause(id)
            paused.insert(id)
        } else if paused.contains(id) {
            paused.remove(id)
            engine.resume(id)
            lastResume = (id, now)
        } else {
            engine.play(id)
        }
    }

    func togglePause() {
        isPaused.toggle()
        if isPaused { engine.pauseAll() } else { engine.resumeAll() }
    }

    func stopAll(fadeOut: Double = 0) {
        isPaused = false
        engine.stopAll(fadeOut: fadeOut)
    }

    private func handle(_ e: PlaybackEvent) {
        switch e {
        case .started(let i): playing.insert(i); paused.remove(i)
        case .stopped(let i): playing.remove(i); paused = paused.filter(engine.isPlaying)  // keeps buttons paused by a tap
        case .ended(let i): playing.remove(i); paused.remove(i)
        }
        if let bid = boardID(of: e.trackID), let b = boards.first(where: { $0.id == bid }) {
            automation.handle(e, board: b, control: engine)
        }
    }
}
