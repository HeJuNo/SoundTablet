import SwiftUI

struct NowPlayingStrip: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = true

    var body: some View {
        let items = model.activeBoard?.tracks.filter { model.playing.contains($0.id) } ?? []
        if !items.isEmpty {
            DisclosureGroup("Now playing (\(items.count))", isExpanded: $expanded) {
                ForEach(items) { ScrubRow(track: $0) }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }
}

private struct ScrubRow: View {
    let track: Track
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Text(track.name).lineLimit(1).frame(maxWidth: 140, alignment: .leading)
            if let r = model.engine.playRange(track.id), r.upperBound > r.lowerBound {
                TimelineView(.animation(minimumInterval: 0.1)) { _ in
                    Slider(value: Binding(get: { model.engine.position(track.id) ?? r.lowerBound },
                                          set: { model.engine.seek(track.id, to: $0) }), in: r)
                }
            }
        }
    }
}
