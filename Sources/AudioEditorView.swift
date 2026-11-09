import SwiftUI

/// Zoomable waveform editor for the excerpt (in/out) of one button: drag the handles, nudge by exact steps,
/// mark from the playhead while listening, optionally snap to zero crossings so loop seams do not click.
struct AudioEditorView: View {
    let trackID: Track.ID
    @Environment(AppModel.self) private var model
    @State private var zoom = 1
    @State private var peaks: [Float] = []
    @State private var step = 0.01
    @State private var snap = true
    @State private var dragIn: Double?
    @State private var dragOut: Double?

    private let zooms = [1, 4, 16, 64]
    private let steps: [(label: String, value: Double)] = [("1 ms", 0.001), ("10 ms", 0.01), ("100 ms", 0.1), ("1 s", 1)]

    var body: some View {
        if let t = model.track(trackID), let duration = model.engine.duration(trackID) {
            let inT = dragIn ?? t.settings.trimIn, outT = dragOut ?? t.settings.trimOut ?? duration
            VStack(alignment: .leading, spacing: 14) {
                transport(t)
                waveform(duration: duration, inT: inT, outT: outT)
                Picker("Zoom", selection: $zoom) { ForEach(zooms, id: \.self) { Text("\($0)×").tag($0) } }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Waveform zoom")
                edit("In", value: inT, minus: { nudge(in: -step) }, plus: { nudge(in: step) }, mark: { mark(in: true) })
                edit("Out", value: outT, minus: { nudge(out: -step) }, plus: { nudge(out: step) }, mark: { mark(in: false) })
                Picker("Step", selection: $step) { ForEach(steps, id: \.value) { Text($0.label).tag($0.value) } }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Nudge step")
                Toggle("Snap to zero crossings", isOn: $snap)
                Text("Length \(LoopDetector.clock(outT - inT)) · the clip repeats from Out back to In when Loop is on.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .task(id: zoom) { await loadPeaks() }
        } else {
            Text("Waveform unavailable").foregroundStyle(.secondary)
        }
    }

    // MARK: pieces

    private func transport(_ t: Track) -> some View {
        HStack {
            Button(model.playing.contains(trackID) ? "Stop" : "Play",
                   systemImage: model.playing.contains(trackID) ? "stop.fill" : "play.fill") { model.tap(trackID) }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Spacer()
            Toggle("Loop", isOn: Binding(get: { t.settings.loop }, set: { v in model.edit(trackID) { $0.settings.loop = v } }))
                .toggleStyle(.button).controlSize(.large)
        }
    }

    private func waveform(duration: Double, inT: Double, outT: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width * CGFloat(zoom), d = max(duration, 0.01)
            ScrollView(.horizontal, showsIndicators: zoom > 1) {
                ZStack(alignment: .leading) {
                    Canvas { ctx, size in
                        let n = max(peaks.count, 1), bw = size.width / CGFloat(n)
                        for (i, p) in peaks.enumerated() {
                            let h = max(1, CGFloat(p) * size.height)
                            ctx.fill(Path(CGRect(x: CGFloat(i) * bw, y: (size.height - h) / 2, width: max(bw - 0.5, 0.5), height: h)),
                                     with: .color(.accentColor))
                        }
                    }
                    Rectangle().fill(.black.opacity(0.5)).frame(width: w * inT / d)
                    Rectangle().fill(.black.opacity(0.5)).frame(width: w * (1 - outT / d)).offset(x: w * outT / d)
                    playhead(width: w, duration: d)
                    handle("Start", time: inT, x: w * inT / d, color: .green)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("wave"))
                            .onChanged { dragIn = min(max(0, $0.location.x / w * d), outT - 0.001) }
                            .onEnded { _ in if let v = dragIn { Task { await commit(inT: v) } }; dragIn = nil })
                        .accessibilityAdjustableAction { dir in nudge(in: dir == .increment ? step : -step) }
                    handle("End", time: outT, x: w * outT / d, color: .red)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("wave"))
                            .onChanged { dragOut = max(min(duration, $0.location.x / w * d), inT + 0.001) }
                            .onEnded { _ in if let v = dragOut { Task { await commit(outT: v) } }; dragOut = nil })
                        .accessibilityAdjustableAction { dir in nudge(out: dir == .increment ? step : -step) }
                }
                .frame(width: w, height: 110)
                .coordinateSpace(name: "wave")
            }
        }
        .frame(height: 110)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemFill)))
    }

    /// Line + 44 pt wide hit area (HIG minimum touch target) so the handle is easy to grab at any zoom.
    private func handle(_ name: String, time: Double, x: CGFloat, color: Color) -> some View {
        ZStack {
            Rectangle().fill(color).frame(width: 3)
            Circle().fill(color).frame(width: 14, height: 14).offset(y: -48)
        }
        .frame(width: 44, height: 110)
        .contentShape(Rectangle())
        .offset(x: x - 22)
        .accessibilityLabel("\(name) point").accessibilityValue(LoopDetector.clock(time))
    }

    private func playhead(width: CGFloat, duration: Double) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !model.playing.contains(trackID))) { _ in
            if let p = model.engine.position(trackID), model.playing.contains(trackID) {
                Rectangle().fill(.white).frame(width: 2, height: 110).offset(x: width * p / duration - 1)
            }
        }
        .allowsHitTesting(false)
    }

    private func edit(_ label: String, value: Double, minus: @escaping () -> Void, plus: @escaping () -> Void, mark: @escaping () -> Void) -> some View {
        HStack {
            Text(label).font(.headline).frame(width: 36, alignment: .leading)
            Text(LoopDetector.clock(value)).font(.body.monospacedDigit())
            Spacer()
            iconButton("scope", "Set \(label) to playhead", action: mark).disabled(!model.playing.contains(trackID))
            iconButton("minus", "\(label) earlier", action: minus)
            iconButton("plus", "\(label) later", action: plus)
        }
        .buttonStyle(.bordered).controlSize(.large)
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 28, height: 28) }  // equal width, >= 44 pt target
            .accessibilityLabel(label)
    }

    // MARK: actions

    private func nudge(in d: Double = 0, out o: Double = 0) {
        guard let t = model.track(trackID), let dur = model.engine.duration(trackID) else { return }
        Task {
            if d != 0 { await commit(inT: t.settings.trimIn + d) }
            if o != 0 { await commit(outT: (t.settings.trimOut ?? dur) + o) }
        }
    }

    private func mark(in isIn: Bool) {
        guard let p = model.engine.position(trackID) else { return }
        Task { isIn ? await commit(inT: p) : await commit(outT: p) }
    }

    /// Applies one edge (snapping to a zero crossing when enabled); the model clamps to the file.
    private func commit(inT: Double? = nil, outT: Double? = nil) async {
        guard let t = model.track(trackID), let dur = model.engine.duration(trackID) else { return }
        let url = await model.audioURL(for: trackID)
        func snapped(_ v: Double) async -> Double {
            guard snap, let url else { return v }
            return await ZeroCrossing.nearestTime(url: url, to: v)
        }
        let newIn = await inT.asyncMap(snapped) ?? t.settings.trimIn
        let newOut = await outT.asyncMap(snapped) ?? t.settings.trimOut
        await model.setTrim(trackID, trimIn: max(0, min(newIn, dur)), trimOut: newOut.map { min($0, dur) })
    }

    private func loadPeaks() async {
        guard let url = await model.audioURL(for: trackID) else { return }
        // 240 bars per screen width; capped so 64x on a long file stays cheap.
        peaks = (try? await waveformPeaks(url: url, buckets: min(240 * zoom, 12000))) ?? []
    }
}

private extension Optional {
    func asyncMap<T>(_ f: (Wrapped) async -> T) async -> T? {
        if let v = self { return await f(v) }
        return nil
    }
}
