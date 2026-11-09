import SwiftUI

/// Where the global Pause / Stop / Fade out controls live. Three designs, chosen in Defaults.
enum TransportStyle: String, CaseIterable, Identifiable {
    case toolbar     // A: system bottom toolbar
    case floating    // B: floating glass control with large round buttons
    case prominent   // C: wide Stop button plus Pause and a Fade-out menu

    var id: String { rawValue }
    var title: String {
        switch self {
        case .toolbar: "Toolbar"
        case .floating: "Floating"
        case .prominent: "Large Stop"
        }
    }
}

private let fadeDurations: [Double] = [1, 3, 5]

/// A: standard bottom toolbar (HIG: toolbars hold the frequent actions of the current screen; system sizing,
/// materials and hit targets).
struct TransportToolbar: ToolbarContent {
    let model: AppModel
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            // Text buttons: the toolbar drops titles of icon+title labels, and three look-alike icons are hard to tell apart.
            Button(model.isPaused ? "Resume" : "Pause") { model.togglePause() }
            Spacer()
            Button("Stop", role: .destructive) { model.stopAll() }
            Spacer()
            Button("Fade out") { model.stopAll(fadeOut: 2) }
        }
    }
}

/// B: floating Liquid Glass buttons (system `.glass` styles: system sizing, Dynamic Type and contrast handled by the
/// system). Stop is red and prominent; the row stacks vertically when text is very large.
struct FloatingTransport: View {
    let model: AppModel
    var body: some View {
        GlassEffectContainer(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { buttons }
                VStack(spacing: 12) { buttons }
            }
        }
        .controlSize(.large)  // 49 pt tall buttons: HIG 44 pt minimum hit target
        .labelStyle(.titleAndIcon)
        .padding(.horizontal).padding(.bottom, 8)
    }

    @ViewBuilder private var buttons: some View {
        Button(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill") { model.togglePause() }
            .buttonStyle(.glass)
        Button("Stop", systemImage: "stop.fill") { model.stopAll() }
            .buttonStyle(.glassProminent).tint(.red)
        Button("Fade out", systemImage: "speaker.slash.fill") { model.stopAll(fadeOut: 2) }
            .buttonStyle(.glass)
    }
}

/// C: one wide, red Stop (the action you need fastest and most reliably during a show) with Pause and a
/// Fade-out menu (tap = 2 s, hold = 1 / 3 / 5 s) beside it. Opaque bar so contrast does not depend on what scrolls under it.
struct ProminentTransport: View {
    let model: AppModel
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { controls }
            VStack(spacing: 10) { controls }
        }
        .controlSize(.large)  // 49 pt tall buttons: HIG 44 pt minimum hit target
        .labelStyle(.titleAndIcon)
        .padding(.horizontal).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
    }

    @ViewBuilder private var controls: some View {
        Button(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill") { model.togglePause() }
            .buttonStyle(.bordered).tint(.primary).fixedSize()  // primary text on grey: higher contrast than blue on grey
        Button { model.stopAll() } label: { Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent).tint(.red.mix(with: .black, by: 0.25))  // white on system red is only ~3.9:1; this is >4.5:1
        Menu {
            ForEach(fadeDurations, id: \.self) { d in Button("Fade out over \(Int(d)) s") { model.stopAll(fadeOut: d) } }
        } label: { Label("Fade out", systemImage: "speaker.slash.fill") } primaryAction: { model.stopAll(fadeOut: 2) }
            .buttonStyle(.bordered).tint(.primary).fixedSize()
    }
}

/// B and C sit under the grid; A is part of the toolbar (see BoardView) and draws nothing here.
struct GlobalBar: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        switch model.transportStyle {
        case .toolbar: EmptyView()
        case .floating: FloatingTransport(model: model)
        case .prominent: ProminentTransport(model: model)
        }
    }
}
