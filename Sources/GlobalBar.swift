import SwiftUI

struct GlobalBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Button(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill") { model.togglePause() }
            Button("Stop", systemImage: "stop.fill") { model.stopAll() }
            Button("Fade out", systemImage: "speaker.slash.fill") { model.stopAll(fadeOut: 2) }
        }
        .buttonStyle(.bordered)
        .labelStyle(.titleAndIcon)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}
