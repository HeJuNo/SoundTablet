import PhotosUI
import SwiftUI

struct TrackSettingsView: View {
    let trackID: Track.ID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var suggesting = false
    @State private var photo: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            if let t = model.track(trackID) {
                Form {
                    Section("Track") {
                        TextField("Name", text: bind(t, \.name))
                        TextField("Second line (optional)", text: Binding(get: { t.subtitle ?? "" },
                                                                         set: { v in model.edit(trackID) { $0.subtitle = v.isEmpty ? nil : v } }))
                        ColorSwatches(selected: t.colorHex) { c in model.edit(trackID) { $0.colorHex = c } }
                    }
                    Section("Playback") {
                        HStack { Text("Volume"); Slider(value: bind(t, \.settings.volume), in: 0...1) }
                        Toggle("Match reference loudness", isOn: Binding(get: { t.settings.normalize },
                                                                         set: { v in Task { await model.setNormalize(trackID, v) } }))
                            .disabled(model.referenceDB == nil)
                        Toggle("Loop", isOn: bind(t, \.settings.loop))
                        Toggle("Solo (stops all other tracks)", isOn: bind(t, \.settings.solo))
                        Stepper("Fade in: \(t.settings.fadeIn, specifier: "%.1f") s", value: bind(t, \.settings.fadeIn), in: 0...10, step: 0.5)
                        Stepper("Fade out: \(t.settings.fadeOut, specifier: "%.1f") s", value: bind(t, \.settings.fadeOut), in: 0...10, step: 0.5)
                    }
                    Section("Excerpt & loop") {
                        AudioEditorView(trackID: trackID)
                        Button("Find loops & sections", systemImage: "wand.and.sparkles") { suggesting = true }
                    }
                    Section("Automations") { AutomationEditor(track: t) }
                    Section("Image") {
                        PhotosPicker("Choose image", selection: $photo, matching: .images)
                        if t.imageFileName != nil { Button("Remove image", role: .destructive) { Task { await model.setImage(trackID, data: nil) } } }
                    }
                    Section { Button("Delete track", role: .destructive) { Task { await model.deleteTrack(trackID); dismiss() } } }
                }
                .navigationTitle(t.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() } }
                .sheet(isPresented: $suggesting) { LoopSuggestionsView(trackID: trackID) }
                .onChange(of: photo) {
                    guard let photo else { return }
                    Task { if let d = try? await photo.loadTransferable(type: Data.self) { await model.setImage(trackID, data: d) } }
                }
            }
        }
    }

    private func bind<V>(_ t: Track, _ kp: WritableKeyPath<Track, V>) -> Binding<V> {
        Binding(get: { t[keyPath: kp] }, set: { v in model.edit(trackID) { $0[keyPath: kp] = v } })
    }
}

struct ColorSwatches: View {
    let selected: String
    let pick: (String) -> Void
    var body: some View {
        HStack {
            ForEach(tilePalette, id: \.self) { hex in
                Button { pick(hex) } label: {
                    Circle().fill(Color(hex: hex)).frame(width: 28, height: 28)
                        .overlay(Circle().stroke(.primary, lineWidth: hex == selected ? 3 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Colour \(hex)").accessibilityAddTraits(hex == selected ? .isSelected : [])
            }
        }
    }
}
