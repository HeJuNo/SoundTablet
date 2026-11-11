import SwiftUI

/// Zoomable waveform editor for the excerpt (in/out) of one button.
/// - Waveform 200 pt tall with a time ruler; pinch or the zoom buttons zoom 1x-64x, "Fit" zooms to the selection.
/// - Playhead: follows playback; tap the waveform to place it (also seeks while playing). The readout always shows
///   position / length.
/// - In/Out: system Steppers (exact steps), drag the handles, or set from the playhead. Dragging and playhead
///   marks can snap to zero crossings so loop seams do not click; Stepper nudges are always exact.
struct AudioEditorView: View {
    let trackID: Track.ID
    @Environment(AppModel.self) private var model
    @State private var zoom = 1.0
    @State private var pinchBase: Double?
    @State private var peaks: [Float] = []
    @State private var step = 0.01
    @State private var snap = true
    @State private var dragIn: Double?
    @State private var dragOut: Double?
    @State private var cue = 0.0                       // playhead while stopped; Play starts here
    @State private var scrub: Double?                  // playhead while it is being dragged
    @State private var undoStack: [(inT: Double, outT: Double?, loop: Bool)] = []  // earlier In / Out / Loop states, newest last
    @State private var dragOrigin: Double?             // time of the grabbed handle / playhead when the drag began
    @State private var scroll = ScrollPosition(edge: .leading)
    @State private var offsetX: CGFloat = 0
    @State private var viewW: CGFloat = 300

    private let waveHeight: CGFloat = 200
    private let inset: CGFloat = 14                     // room so the End handle is never clipped
    private let steps: [(label: String, value: Double)] = [("1 ms", 0.001), ("10 ms", 0.01), ("100 ms", 0.1), ("1 s", 1)]
    /// Peaks are computed per power-of-two tier, so pinching does not reload on every frame.
    private var tier: Int { [1, 2, 4, 8, 16, 32, 64].first { Double($0) >= zoom } ?? 64 }

    var body: some View {
        if let t = model.track(trackID), let duration = model.engine.duration(trackID) {
            let inT = dragIn ?? t.settings.trimIn, outT = dragOut ?? t.settings.trimOut ?? duration
            VStack(alignment: .leading, spacing: 12) {
                transport(t, duration: duration)
                waveform(duration: duration, inT: inT, outT: outT)
                zoomRow(duration: duration, inT: inT, outT: outT)
                inOut(inT: inT, outT: outT, duration: duration)
            }
            .task(id: tier) { await loadPeaks() }
            .onChange(of: model.playing.contains(trackID)) { _, playing in
                if !playing, let p = model.engine.position(trackID) { cue = p }
            }
        } else {
            Text("Waveform unavailable").foregroundStyle(.secondary)
        }
    }

    // MARK: transport + readout

    private func transport(_ t: Track, duration: Double) -> some View {
        HStack {
            let playing = model.playing.contains(trackID)
            Button(playing ? "Stop" : "Play", systemImage: playing ? "stop.fill" : "play.fill") {
                if playing { model.stop(trackID) } else { model.play(trackID, from: cue) }
            }
                .buttonStyle(.borderedProminent)
            Toggle(isOn: Binding(get: { t.settings.loop }, set: { v in remember(t); model.edit(trackID) { $0.settings.loop = v } })) {
                Label("Loop", systemImage: "repeat")
            }
            .toggleStyle(.button).buttonStyle(.bordered)
            Spacer()
            TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !playing)) { _ in
                Text("\(LoopDetector.clock(position)) / \(LoopDetector.clock(duration))")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityLabel("Position \(LoopDetector.clock(position)) of \(LoopDetector.clock(duration))")
            }
        }
        .labelStyle(.titleAndIcon)
    }

    /// Where the audio is right now: the live playhead while playing, otherwise the cue the user placed.
    private var position: Double { scrub ?? (model.playing.contains(trackID) ? (model.engine.position(trackID) ?? cue) : cue) }

    // MARK: waveform

    private func waveform(duration: Double, inT: Double, outT: Double) -> some View {
        GeometryReader { geo in
            let w = (geo.size.width - 2 * inset) * CGFloat(zoom), d = max(duration, 0.01)
            ScrollView(.horizontal, showsIndicators: zoom > 1) {
                ZStack(alignment: .leading) {
                    Canvas { ctx, size in
                        let n = max(peaks.count, 1), bw = (size.width - 2 * inset) / CGFloat(n)
                        let top: CGFloat = 20, h0 = size.height - top
                        for (i, p) in peaks.enumerated() {
                            let h = max(1, CGFloat(p) * h0)
                            ctx.fill(Path(CGRect(x: inset + CGFloat(i) * bw, y: top + (h0 - h) / 2, width: max(bw - 0.5, 0.5), height: h)),
                                     with: .color(.accentColor))
                        }
                        drawRuler(ctx, size: size, duration: d, width: w)
                    }
                    Rectangle().fill(.black.opacity(0.5)).frame(width: inset + w * inT / d).padding(.top, 20)
                    Rectangle().fill(.black.opacity(0.5)).frame(width: w * (1 - outT / d) + inset).offset(x: inset + w * outT / d).padding(.top, 20)
                    playhead(width: w, duration: d)
                    handle("Start", time: inT, x: inset + w * inT / d, color: .green)
                        .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("wave"))
                            .onChanged { g in
                                dragOrigin = dragOrigin ?? inT  // move by the finger's travel, so the handle does not jump to the touch point
                                dragIn = min(max(0, dragOrigin! + g.translation.width / w * d), outT - 0.001)
                            }
                            .onEnded { _ in
                                dragOrigin = nil
                                if let v = dragIn { Task { await commit(inT: v, snapping: snap); dragIn = nil } }  // keep the handle where it is until the snapped value is stored
                            })
                        .accessibilityAdjustableAction { dir in nudge(in: dir == .increment ? step : -step) }
                    handle("End", time: outT, x: inset + w * outT / d, color: .red)
                        .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("wave"))
                            .onChanged { g in
                                dragOrigin = dragOrigin ?? outT
                                dragOut = max(min(duration, dragOrigin! + g.translation.width / w * d), inT + 0.001)
                            }
                            .onEnded { _ in
                                dragOrigin = nil
                                if let v = dragOut { Task { await commit(outT: v, snapping: snap); dragOut = nil } }
                            })
                        .accessibilityAdjustableAction { dir in nudge(out: dir == .increment ? step : -step) }
                }
                .frame(width: w + 2 * inset, height: waveHeight)
                .contentShape(Rectangle())
                .coordinateSpace(name: "wave")
                .onTapGesture(coordinateSpace: .named("wave")) { loc in place(at: min(max(0, (loc.x - inset) / w * d), d)) }
            }
            .scrollDisabled(dragIn != nil || dragOut != nil || scrub != nil)  // a drag on a handle or the playhead must not scroll
            .scrollPosition($scroll)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in offsetX = x }
            .simultaneousGesture(MagnifyGesture()
                .onChanged { v in
                    pinchBase = pinchBase ?? zoom
                    setZoom((pinchBase ?? zoom) * v.magnification, duration: d, keepCenter: true)
                }
                .onEnded { _ in pinchBase = nil })
            .onAppear { viewW = geo.size.width }
            .onChange(of: geo.size.width) { _, v in viewW = v }
        }
        .frame(height: waveHeight)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemFill)))
    }

    /// Time ruler along the top: tick spacing adapts so labels stay >= 70 pt apart.
    private func drawRuler(_ ctx: GraphicsContext, size: CGSize, duration d: Double, width w: CGFloat) {
        let candidates: [Double] = [0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 30, 60, 120]
        let pxPerSec = w / CGFloat(d)
        let spacing = candidates.first { CGFloat($0) * pxPerSec >= 70 } ?? 120
        var t = 0.0
        while t <= d {
            let x = inset + CGFloat(t) * pxPerSec
            ctx.fill(Path(CGRect(x: x, y: 14, width: 1, height: 6)), with: .color(.secondary))
            ctx.draw(Text(LoopDetector.clock(t)).font(.caption2).foregroundColor(.secondary),
                     at: CGPoint(x: x + 3, y: 7), anchor: .leading)
            t += spacing
        }
    }

    /// Thin line + knob, with a 44 pt wide hit area (HIG minimum) so it is easy to grab at any zoom.
    private func handle(_ name: String, time: Double, x: CGFloat, color: Color) -> some View {
        ZStack {
            Rectangle().fill(color).frame(width: 2).padding(.top, 20)
            Circle().fill(color).frame(width: 12, height: 12).offset(y: -waveHeight / 2 + 26)
        }
        .frame(width: 44, height: waveHeight)
        .contentShape(Path(CGRect(x: 0, y: 0, width: 44, height: waveHeight * 0.55)))  // upper part only: the playhead is grabbed at the bottom, so both stay reachable on the same spot
        .offset(x: x - 22)
        .accessibilityLabel("\(name) point").accessibilityValue(LoopDetector.clock(time))
    }

    /// Playhead: drag its bottom knob (44 x 56 pt grab area) to scrub; the rest of the line lets taps through to place it.
    /// The handles are grabbed in the upper half, so a handle and the playhead on the same spot never block each other.
    private func playhead(width: CGFloat, duration: Double) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !model.playing.contains(trackID))) { _ in
            ZStack(alignment: .top) {
                Rectangle().fill(.primary).frame(width: 2)
                Image(systemName: "arrowtriangle.down.fill").font(.system(size: 9)).offset(y: -6)
            }
            .padding(.top, 20)
            .frame(width: 44, height: waveHeight, alignment: .top)
            .overlay(alignment: .bottom) { Image(systemName: "arrowtriangle.up.circle.fill").font(.system(size: 22)).padding(.bottom, 6) }
            .contentShape(Path(CGRect(x: 0, y: waveHeight - 56, width: 44, height: 56)))
            .offset(x: inset + width * position / duration - 22)
            .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("wave"))
                .onChanged { g in
                    dragOrigin = dragOrigin ?? position
                    scrub = min(max(0, dragOrigin! + g.translation.width / width * duration), duration)
                }
                .onEnded { _ in
                    dragOrigin = nil
                    if let t = scrub { place(at: t) }
                    scrub = nil
                })
            .accessibilityElement().accessibilityLabel("Playhead").accessibilityValue(LoopDetector.clock(position))
            .accessibilityAdjustableAction { dir in place(at: min(max(0, position + (dir == .increment ? step : -step)), duration)) }
        }
    }

    // MARK: zoom

    private func zoomRow(duration: Double, inT: Double, outT: Double) -> some View {
        HStack {
            Button("Zoom out", systemImage: "minus.magnifyingglass") { setZoom(zoom / 2, duration: duration, keepCenter: true) }
                .disabled(zoom <= 1)
            Text("\(zoom < 10 ? String(format: "%.1f", zoom) : String(Int(zoom)))×")
                .font(.subheadline.monospacedDigit()).frame(minWidth: 44)
                .accessibilityLabel("Zoom \(Int(zoom)) times")
            Button("Zoom in", systemImage: "plus.magnifyingglass") { setZoom(zoom * 2, duration: duration, keepCenter: true) }
                .disabled(zoom >= 64)
            Spacer()
            Button("Fit selection", systemImage: "arrow.left.and.right.square") { fit(duration: duration, inT: inT, outT: outT) }
        }
        .buttonStyle(.bordered).labelStyle(.iconOnly)
    }

    private func setZoom(_ z: Double, duration: Double, keepCenter: Bool) {
        let old = zoom, new = min(max(z, 1), 64)
        guard new != old else { return }
        let content = viewW - 2 * inset
        let centerFrac = (offsetX + viewW / 2 - inset) / (content * CGFloat(old))
        zoom = new
        if keepCenter { scroll.scrollTo(x: max(0, inset + centerFrac * content * CGFloat(new) - viewW / 2)) }
    }

    private func fit(duration: Double, inT: Double, outT: Double) {
        let f = max((outT - inT) / max(duration, 0.01), 1.0 / 64)
        zoom = min(max(0.9 / f, 1), 64)
        let content = viewW - 2 * inset
        scroll.scrollTo(x: max(0, inset + CGFloat(inT / max(duration, 0.01)) * content * CGFloat(zoom) - viewW * 0.05))
    }

    // MARK: in / out

    private func inOut(inT: Double, outT: Double, duration: Double) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Stepper(value: Binding(get: { inT }, set: { v in nudgeTo(inT: v) }), in: 0...max(0, outT - 0.001), step: step) {
                HStack { Text("In").fontWeight(.semibold); Text(LoopDetector.clock(inT)).monospacedDigit() }
            }
            Stepper(value: Binding(get: { outT }, set: { v in nudgeTo(outT: v) }), in: min(duration, inT + 0.001)...duration, step: step) {
                HStack { Text("Out").fontWeight(.semibold); Text(LoopDetector.clock(outT)).monospacedDigit() }
            }
            HStack {
                Button("Set In") { Task { await commit(inT: position, snapping: snap) } }
                    .accessibilityLabel("Set In to playhead")
                Button("Set Out") { Task { await commit(outT: position, snapping: snap) } }
                    .accessibilityLabel("Set Out to playhead")
                Button("Undo", systemImage: "arrow.uturn.backward") { undo() }
                    .disabled(undoStack.isEmpty)
                Spacer()
                Text("Length \(LoopDetector.clock(outT - inT))").font(.footnote).foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered).controlSize(.small)
            HStack {
                Picker("Step", selection: $step) { ForEach(steps, id: \.value) { Text($0.label).tag($0.value) } }
                    .pickerStyle(.menu)
                Spacer()
                Toggle("Snap", isOn: $snap).fixedSize().accessibilityLabel("Snap to zero crossings")
            }
        }
    }

    // MARK: actions

    private func remember(_ t: Track) {
        undoStack.append((t.settings.trimIn, t.settings.trimOut, t.settings.loop))
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    /// Takes back the last change to In, Out or Loop.
    private func undo() {
        guard let u = undoStack.popLast() else { return }
        model.edit(trackID) { $0.settings.loop = u.loop }
        Task { await model.setTrim(trackID, trimIn: u.inT, trimOut: u.outT) }
    }

    private func place(at time: Double) {
        cue = time
        if model.playing.contains(trackID) { model.engine.seek(trackID, to: time) }
    }

    private func nudge(in d: Double = 0, out o: Double = 0) {
        guard let t = model.track(trackID), let dur = model.engine.duration(trackID) else { return }
        if d != 0 { nudgeTo(inT: t.settings.trimIn + d) }
        if o != 0 { nudgeTo(outT: (t.settings.trimOut ?? dur) + o) }
    }

    /// Stepper changes are exact (no zero-crossing snap), so 1 ms steps always move.
    private func nudgeTo(inT: Double? = nil, outT: Double? = nil) {
        Task { await commit(inT: inT, outT: outT, snapping: false) }
    }

    /// Applies one edge (optionally snapped to a zero crossing); the model clamps to the file.
    private func commit(inT: Double? = nil, outT: Double? = nil, snapping: Bool) async {
        guard let t = model.track(trackID), let dur = model.engine.duration(trackID) else { return }
        let url = await model.audioURL(for: trackID)
        func snapped(_ v: Double) async -> Double {
            guard snapping, let url else { return v }
            return await ZeroCrossing.nearestTime(url: url, to: v)
        }
        remember(t)
        var newIn = t.settings.trimIn, newOut = t.settings.trimOut
        if let v = inT { newIn = await snapped(v) }
        if let v = outT { newOut = await snapped(v) }
        await model.setTrim(trackID, trimIn: max(0, min(newIn, dur)), trimOut: newOut.map { min($0, dur) })
    }

    private func loadPeaks() async {
        guard let url = await model.audioURL(for: trackID) else { return }
        // 240 bars per screen width at tier 1; capped so 64x on a long file stays cheap.
        peaks = (try? await waveformPeaks(url: url, buckets: min(240 * tier, 12000))) ?? []
    }
}
