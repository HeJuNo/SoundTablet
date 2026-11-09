import Foundation

struct TrackSettings: Codable, Equatable, Sendable {
    var volume: Float = 1
    var loop = false
    var solo = false
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var trimIn: Double = 0
    var trimOut: Double? = nil  // nil = end of file
    var normalize = false       // match the reference loudness from Defaults
    var loudnessDB: Double? = nil  // cached measurement of this track's file (set when normalize is turned on)

    static let `default` = TrackSettings()

    init() {}
    /// Tolerant decoding: boards saved before a field existed still load.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        loop = try c.decodeIfPresent(Bool.self, forKey: .loop) ?? false
        solo = try c.decodeIfPresent(Bool.self, forKey: .solo) ?? false
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0
        trimIn = try c.decodeIfPresent(Double.self, forKey: .trimIn) ?? 0
        trimOut = try c.decodeIfPresent(Double.self, forKey: .trimOut)
        normalize = try c.decodeIfPresent(Bool.self, forKey: .normalize) ?? false
        loudnessDB = try c.decodeIfPresent(Double.self, forKey: .loudnessDB)
    }
}

enum AutomationTrigger: String, Codable, Sendable { case started, stopped, ended }

enum AutomationAction: Codable, Equatable, Sendable {
    case play, stop, setVolume(Float)
}

struct Automation: Codable, Equatable, Sendable {
    var trigger: AutomationTrigger
    var action: AutomationAction
    var target: Track.ID
}

struct Track: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var subtitle: String? = nil  // optional second tile line (smaller, regular weight)
    var fileName: String
    var colorHex: String
    var imageFileName: String? = nil
    var settings: TrackSettings = .default
    var automations: [Automation] = []
}

struct Board: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var colorHex: String
    var tracks: [Track] = []  // order = tile order
    var sortIndex = 0         // board order
}
