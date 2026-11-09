import SwiftUI

/// Finds loop/section candidates in a button's audio file. Pick one or more: use one for this button, or add each
/// as a new button that shares the same file. Tap the speaker to audition a candidate first.
struct LoopSuggestionsView: View {
    let trackID: Track.ID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [LoopCandidate] = []
    @State private var loading = true
    @State private var selected: Set<UUID> = []
    @State private var auditioning: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if loading { ProgressView("Analysing audio…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if candidates.isEmpty {
                    ContentUnavailableView("No loops found", systemImage: "waveform.slash",
                                           description: Text("This audio has no clear tempo or separate sections. Set In and Out by hand in the editor."))
                } else { list }
            }
            .navigationTitle("Suggested loops")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { close() } } }
            .safeAreaInset(edge: .bottom) { if !candidates.isEmpty { actions } }
            .task {
                if let url = await model.audioURL(for: trackID) { candidates = (try? await LoopDetector.candidates(url: url)) ?? [] }
                loading = false
            }
        }
        .presentationDetents([.medium, .large])
        .onDisappear { model.stopPreview() }
    }

    private var list: some View {
        List(candidates) { c in
            HStack(spacing: 12) {
                Button { toggle(c) } label: {
                    Image(systemName: selected.contains(c.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title2).foregroundStyle(selected.contains(c.id) ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain).frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Select \(c.title)").accessibilityAddTraits(selected.contains(c.id) ? .isSelected : [])
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title).font(.body)
                    Text(c.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(auditioning == c.id ? "Stop" : "Listen", systemImage: auditioning == c.id ? "stop.circle.fill" : "speaker.wave.2.circle.fill") {
                    audition(c)
                }
                .labelStyle(.iconOnly).font(.title2).buttonStyle(.plain).frame(minWidth: 44, minHeight: 44)
            }
        }
        .listStyle(.plain)
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button("Use for this button") { useOne() }
                .buttonStyle(.bordered).disabled(selected.count != 1)
            Button(selected.count > 1 ? "Add \(selected.count) new buttons" : "Add as new button") { addNew() }
                .buttonStyle(.borderedProminent).disabled(selected.isEmpty)
        }
        .controlSize(.large).frame(maxWidth: .infinity).padding().background(.bar)
    }

    private func toggle(_ c: LoopCandidate) {
        if selected.contains(c.id) { selected.remove(c.id) } else { selected.insert(c.id) }
    }

    private func audition(_ c: LoopCandidate) {
        if auditioning == c.id { model.stopPreview(); auditioning = nil; return }
        auditioning = c.id
        Task { await model.preview(trackID, start: c.start, end: c.end) }
    }

    private func close() { model.stopPreview(); dismiss() }

    private func useOne() {
        guard let c = candidates.first(where: { selected.contains($0.id) }) else { return }
        model.stopPreview()
        Task {
            await model.setTrim(trackID, trimIn: c.start, trimOut: c.end)
            model.edit(trackID) { $0.settings.loop = true }
            dismiss()
        }
    }

    private func addNew() {
        let base = model.track(trackID)?.name ?? "Loop"
        let items = candidates.filter { selected.contains($0.id) }
            .map { (name: "\(base) · \($0.title)", subtitle: Optional($0.title), start: $0.start, end: $0.end) }
        model.stopPreview()
        Task { await model.addExcerpts(from: trackID, items); dismiss() }
    }
}
