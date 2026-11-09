import SwiftUI

struct TileView: View {
    let track: Track

    static func icons(_ s: TrackSettings, hasAutomations: Bool) -> [(symbol: String, name: String, on: Bool)] {
        [("arrow.up.right", "Fade in", s.fadeIn > 0), ("headphones", "Solo", s.solo), ("repeat", "Loop", s.loop),
         ("wand.and.stars", "Automations", hasAutomations), ("arrow.down.right", "Fade out", s.fadeOut > 0)]
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
                    Color.clear.aspectRatio(1, contentMode: .fit)  // at least square; taller when larger text needs it
                    // Own dark surface in light and dark mode: white text must never sit on a pale tint.
                    RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.12))
                    RoundedRectangle(cornerRadius: 10)
                        .fill(color.opacity(isPlaying ? 0.3 + 0.45 * level : 0.28))
                    if let image { Image(uiImage: image).resizable().scaledToFill().clipShape(RoundedRectangle(cornerRadius: 10)).opacity(0.35) }
                    VStack(spacing: 0) {
                        HStack(spacing: 6) {  // only active settings, full strength on a dark chip: readable at a glance
                            ForEach(Self.icons(s, hasAutomations: !track.automations.isEmpty).filter(\.on), id: \.symbol) { icon in
                                Image(systemName: icon.symbol).font(.system(size: 13, weight: .semibold))  // fixed: decorative chip, state is in the tile's value
                                    .frame(width: 26, height: 26)
                                    .background(.black.opacity(0.4), in: Circle())
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 26)
                        .padding(.horizontal, 10).padding(.top, 10)
                        .accessibilityHidden(true)
                        Spacer(minLength: 0)
                        VStack(spacing: 2) {
                            if missing { Image(systemName: "exclamationmark.triangle") }
                            Text(track.name).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                            if let sub = track.subtitle {
                                Text(sub).font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(2).multilineTextAlignment(.center)
                            }
                        }
                        .padding(.horizontal, 8)
                        Spacer(minLength: 0)
                        HStack {  // elapsed left, remaining right
                            Text(Self.clock(range.map { pos - $0.lowerBound } ?? 0))
                            Spacer()
                            Text("-" + Self.clock(range.map { $0.upperBound - pos } ?? 0))
                        }
                        .font(.caption.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                        .accessibilityHidden(true)  // decoration: VoiceOver gets the state through the tile's value
                        .padding(.horizontal, 12).padding(.bottom, 12)
                    }
                    .foregroundStyle(.white)
                }
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
        .accessibilityValue(([missing ? "Audio file missing" : isPlaying ? "Playing" : "Stopped"]
            + Self.icons(track.settings, hasAutomations: !track.automations.isEmpty).filter(\.on).map(\.name)).joined(separator: ", "))
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
