import SwiftUI

struct TileView: View {
    let track: Track

    static func icons(_ s: TrackSettings, hasAutomations: Bool) -> [(symbol: String, on: Bool)] {
        [("arrow.up.right", s.fadeIn > 0), ("headphones", s.solo), ("repeat", s.loop),
         ("wand.and.stars", hasAutomations), ("arrow.down.right", s.fadeOut > 0)]
    }

    /// mm:ss, rounded down like a player clock.
    static func clock(_ t: Double) -> String {
        let n = Int(max(0, t)); return String(format: "%02d:%02d", n / 60, n % 60)
    }

    @Environment(AppModel.self) private var model
    @State private var image: UIImage?

    var body: some View {
        let isPlaying = model.playing.contains(track.id)
        let missing = model.unavailable.contains(track.id)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPlaying)) { _ in
            let level = Double(model.engine.level(track.id))  // tile pulses with the live level
            let color = Color(hex: track.colorHex)
            let s = track.settings
            let range = model.engine.playRange(track.id)
            let pos = isPlaying ? (model.engine.position(track.id) ?? range?.lowerBound ?? 0) : (range?.lowerBound ?? 0)
            Button { model.tap(track.id) } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(color.opacity(isPlaying ? 0.28 + 0.4 * level : 0.25))
                    if let image { Image(uiImage: image).resizable().scaledToFill().clipShape(RoundedRectangle(cornerRadius: 10)).opacity(0.35) }
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {  // icon row: lit = setting is on
                            ForEach(Self.icons(s, hasAutomations: !track.automations.isEmpty), id: \.symbol) { icon in
                                Image(systemName: icon.symbol).font(.system(size: 14))
                                    .frame(maxWidth: .infinity).opacity(icon.on ? 0.6 : 0.1)
                            }
                        }
                        .padding(10)
                        Spacer(minLength: 0)
                        VStack {
                            if missing { Image(systemName: "exclamationmark.triangle") }
                            Text(track.name).font(.headline).lineLimit(3).multilineTextAlignment(.center)
                        }
                        Spacer(minLength: 0)
                        HStack {  // elapsed left, remaining right
                            Text(Self.clock(range.map { pos - $0.lowerBound } ?? 0))
                            Spacer()
                            Text("-" + Self.clock(range.map { $0.upperBound - pos } ?? 0))
                        }
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 12).padding(.bottom, 12)
                    }
                    .foregroundStyle(.white)
                }
                .aspectRatio(1, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(color, lineWidth: isPlaying ? 5 : 0))
            }
            .buttonStyle(.plain)
        }
        .task(id: track.imageFileName) {
            guard track.imageFileName != nil, let url = await model.audioURL(for: track.id, imageFile: true) else { image = nil; return }
            image = UIImage(contentsOfFile: url.path)
        }
        .opacity(missing ? 0.35 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(track.name)
        .accessibilityValue(missing ? "Audio file missing" : isPlaying ? "Playing" : "Stopped")
        .contextMenu {
            Button("Settings", systemImage: "slider.horizontal.3") { model.editingTrackID = track.id }
            Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.deleteTrack(track.id) } }
        }
        .draggable(track.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, let id = UUID(uuidString: s) else { return false }
            Task { await model.moveTrack(id, before: track.id) }
            return true
        }
    }
}
