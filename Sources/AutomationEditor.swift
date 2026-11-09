import SwiftUI

struct AutomationEditor: View {
    let track: Track
    @Environment(AppModel.self) private var model
    @State private var trigger = AutomationTrigger.started
    @State private var kind = 0   // 0 play, 1 stop, 2 volume
    @State private var volume: Float = 0.3
    @State private var target: Track.ID?

    private var others: [Track] { model.activeBoard?.tracks.filter { $0.id != track.id } ?? [] }
    private func name(_ id: Track.ID) -> String { model.track(id)?.name ?? "?" }

    var body: some View {
        ForEach(Array(track.automations.enumerated()), id: \.offset) { i, a in
            HStack {
                Text(describe(a)).font(.callout)
                Spacer()
                Button("Remove", systemImage: "trash", role: .destructive) { Task { await model.removeAutomation(from: track.id, at: i) } }
                    .labelStyle(.iconOnly)
            }
        }
        if others.isEmpty {
            Text("Add another track to this board to create automations.").font(.footnote).foregroundStyle(.secondary)
        } else {
            Picker("When this track", selection: $trigger) {
                Text("starts").tag(AutomationTrigger.started)
                Text("stops").tag(AutomationTrigger.stopped)
                Text("reaches its end").tag(AutomationTrigger.ended)
            }
            Picker("Then", selection: $kind) {
                Text("play").tag(0); Text("stop").tag(1); Text("set volume of").tag(2)
            }
            Picker("Track", selection: Binding(get: { target ?? others[0].id }, set: { target = $0 })) {
                ForEach(others) { Text($0.name).tag($0.id) }
            }
            if kind == 2 { Slider(value: $volume, in: 0...1) { Text("Volume") }; Text("\(Int(volume * 100)) %").font(.caption) }
            Button("Add automation", systemImage: "plus") {
                let act: AutomationAction = kind == 0 ? .play : kind == 1 ? .stop : .setVolume(volume)
                Task { await model.addAutomation(to: track.id, Automation(trigger: trigger, action: act, target: target ?? others[0].id)) }
            }
        }
    }

    private func describe(_ a: Automation) -> String {
        let when = switch a.trigger { case .started: "starts"; case .stopped: "stops"; case .ended: "reaches its end" }
        let then = switch a.action { case .play: "play"; case .stop: "stop"; case .setVolume(let v): "set volume to \(Int(v * 100)) % of" }
        return "When this \(when) → \(then) \(name(a.target))"
    }
}
