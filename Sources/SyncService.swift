import Foundation

struct SyncReport: Equatable, Sendable {
    var copiedToCloud = 0
    var copiedToLocal = 0
    var removed = 0            // deletions carried over from the other side
    var conflicts: [String] = []
    var pendingDownloads = 0
    var errors: [String] = []
}

enum ICloudLocation {
    /// nil when iCloud is unavailable (signed out, no entitlement, simulator without an account). Call off the main thread.
    static func containerURL() -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents/SoundTablet")
    }
}

/// Two-way mirror between the local store and an iCloud Drive folder. A file removed on one side is removed on the
/// other too, but only if the other side is unchanged since the last sync (an edit beats a deletion); files iCloud
/// has not downloaded are never taken for deleted. A file changed on both sides keeps the older version as
/// "<name> (Konflikt <date>).<ext>".
final class SyncService: @unchecked Sendable {
    private let local: URL, cloud: URL
    private let fm = FileManager.default
    private var stateURL: URL { local.appendingPathComponent(".sync-state.json") }

    init(local: URL, cloud: URL) { self.local = local; self.cloud = cloud }

    func sync() throws -> SyncReport {
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        try fm.createDirectory(at: cloud, withIntermediateDirectories: true)
        var state = (try? JSONDecoder().decode([String: Double].self, from: Data(contentsOf: stateURL))) ?? [:]
        var report = SyncReport()
        let (localFiles, _) = try files(in: local)
        let (cloudFiles, placeholders) = try files(in: cloud)
        for p in placeholders {  // not downloaded yet: ask iCloud, pick it up on a later sync
            try? fm.startDownloadingUbiquitousItem(at: cloud.appendingPathComponent(p))
            report.pendingDownloads += 1
        }

        let evicted = Set(placeholders.map(Self.realPath))
        for path in Set(localFiles.keys).union(cloudFiles.keys).sorted() where !evicted.contains(path) {
            let l = localFiles[path], c = cloudFiles[path]
            do { try syncOne(path, l, c, &state, &report) } catch { report.errors.append(path) }  // one bad file must not stop the rest
        }
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        return report
    }

    private func syncOne(_ path: String, _ l: Double?, _ c: Double?, _ state: inout [String: Double], _ report: inout SyncReport) throws {
            switch (l, c) {
            case let (l?, nil):
                if let last = state[path], abs(l - last) < 1 { try remove(local, path); state[path] = nil; report.removed += 1 }
                else { try copy(local, cloud, path, mtime: l); state[path] = l; report.copiedToCloud += 1 }
            case let (nil, c?):
                if let last = state[path], abs(c - last) < 1 { try remove(cloud, path); state[path] = nil; report.removed += 1 }
                else { try copy(cloud, local, path, mtime: c); state[path] = c; report.copiedToLocal += 1 }
            case let (l?, c?):
                if abs(l - c) < 1 { state[path] = l; return }
                let last = state[path]
                let lChanged = last.map { abs(l - $0) >= 1 } ?? true
                let cChanged = last.map { abs(c - $0) >= 1 } ?? true
                let localWins = lChanged != cChanged ? lChanged : l > c  // a lone edit wins whatever the clocks say
                if lChanged && cChanged {
                    try keepConflictCopy(of: path, in: localWins ? cloud : local)
                    report.conflicts.append(path)
                }
                if localWins { try copy(local, cloud, path, mtime: l); state[path] = l; report.copiedToCloud += 1 }
                else { try copy(cloud, local, path, mtime: c); state[path] = c; report.copiedToLocal += 1 }
            case (nil, nil): break
            }
    }

    /// relative path -> modification time (seconds); iCloud ".<name>.icloud" placeholders are returned separately.
    private func files(in root: URL) throws -> ([String: Double], [String]) {
        var out: [String: Double] = [:], placeholders: [String] = []
        let base = root.standardizedFileURL.path
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]) else { return ([:], []) }
        for case let u as URL in en {
            let v = try u.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard v.isRegularFile == true else { continue }
            let rel = String(u.standardizedFileURL.path.dropFirst(base.count + 1))
            let name = u.lastPathComponent
            if name == ".sync-state.json" || name == ".DS_Store" || name.hasPrefix(".tmp-") { continue }
            if name.hasPrefix("."), name.hasSuffix(".icloud") { placeholders.append(rel); continue }
            out[rel] = v.contentModificationDate?.timeIntervalSince1970 ?? 0
        }
        return (out, placeholders)
    }

    /// "dir/.name.icloud" -> "dir/name"
    private static func realPath(_ placeholder: String) -> String {
        let u = URL(fileURLWithPath: placeholder), name = u.lastPathComponent
        let real = String(name.dropFirst().dropLast(".icloud".count))
        return u.deletingLastPathComponent().path == "/" ? real : u.deletingLastPathComponent().path.dropFirst() + "/" + real
    }

    /// Removes the file and its folders once they are empty.
    private func remove(_ root: URL, _ path: String) throws {
        var u = root.appendingPathComponent(path)
        try fm.removeItem(at: u)
        u.deleteLastPathComponent()
        while u.standardizedFileURL.path != root.standardizedFileURL.path,
              (try? fm.contentsOfDirectory(atPath: u.path).filter { $0 != ".DS_Store" }.isEmpty) == true {
            try? fm.removeItem(at: u); u.deleteLastPathComponent()
        }
    }

    private func copy(_ from: URL, _ to: URL, _ path: String, mtime: Double) throws {
        let src = from.appendingPathComponent(path), dst = to.appendingPathComponent(path)
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordError: NSError?, inner: Error?
        NSFileCoordinator().coordinate(readingItemAt: src, options: [], writingItemAt: dst, options: .forReplacing, error: &coordError) { r, w in
            // Copy beside the destination, then swap: a failed or interrupted copy never damages the existing file.
            let tmp = w.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString)")
            do {
                try fm.copyItem(at: r, to: tmp)
                try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: tmp.path)
                if fm.fileExists(atPath: w.path) { _ = try fm.replaceItemAt(w, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: w) }
            } catch { try? fm.removeItem(at: tmp); inner = error }
        }
        if let e = coordError ?? inner { throw e }
    }

    private func keepConflictCopy(of path: String, in root: URL) throws {
        let src = root.appendingPathComponent(path)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let ext = src.pathExtension
        var name = src.deletingPathExtension().lastPathComponent + " (Konflikt \(f.string(from: Date())))"
        if !ext.isEmpty { name += ".\(ext)" }
        var dst = src.deletingLastPathComponent().appendingPathComponent(name), n = 2
        while fm.fileExists(atPath: dst.path) {  // two conflicts in the same second
            dst = src.deletingLastPathComponent().appendingPathComponent(name.replacingOccurrences(of: ")", with: " \(n))")); n += 1
        }
        try fm.copyItem(at: src, to: dst)
    }
}
