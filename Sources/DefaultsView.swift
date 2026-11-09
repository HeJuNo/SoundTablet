import SwiftUI

/// Settings applied to every newly imported track.
struct DefaultsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false

    var body: some View {
        @Bindable var m = model
        NavigationStack {
            Form {
                Section("New tracks start with") {
                    HStack { Text("Volume"); Slider(value: $m.defaults.volume, in: 0...1) }
                    Toggle("Loop", isOn: $m.defaults.loop)
                    Toggle("Solo", isOn: $m.defaults.solo)
                    Stepper("Fade in: \(m.defaults.fadeIn, specifier: "%.1f") s", value: $m.defaults.fadeIn, in: 0...10, step: 0.5)
                    Stepper("Fade out: \(m.defaults.fadeOut, specifier: "%.1f") s", value: $m.defaults.fadeOut, in: 0...10, step: 0.5)
                }
                Section {
                    Button(model.referenceName ?? "Choose reference file…", systemImage: "waveform") { choosing = true }
                    if let r = model.referenceDB {
                        Text("Reference level \(r, specifier: "%.1f") dBFS. Louder tracks are turned down to it; quieter ones are left alone.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Match all tracks", systemImage: "speaker.wave.2") { Task { await model.normalizeAll(true) } }
                        Button("Remove reference", role: .destructive) { model.clearReference() }
                    }
                } header: { Text("Loudness reference") }
                Section("Display") {
                    VStack(alignment: .leading) {
                        HStack { Text("Button size"); Spacer(); Text("\(Int(m.tileMinWidth)) pt").foregroundStyle(.secondary).monospacedDigit() }
                        Slider(value: $m.tileMinWidth, in: AppModel.tileWidthRange, step: 10) {
                            Text("Button size")
                        } minimumValueLabel: { Image(systemName: "square.grid.3x3").accessibilityHidden(true) }
                          maximumValueLabel: { Image(systemName: "square.grid.2x2").accessibilityHidden(true) }
                    }
                    Text("The grid fits as many buttons per row as the screen allows at this size.").font(.footnote).foregroundStyle(.secondary)
                    Picker("Pause / Stop / Fade out", selection: $m.transportStyle) {
                        ForEach(TransportStyle.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section("iCloud Drive") {
                    Button("Sync now", systemImage: "arrow.triangle.2.circlepath") { Task { await model.syncNow() } }
                        .disabled(model.isSyncing)
                    Text(model.syncStatus).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.audio]) { result in
                if case .success(let url) = result { Task { await model.setReference(url) } }
            }
            .navigationTitle("Defaults")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done", role: .confirm) { dismiss() } }
        }
    }
}
