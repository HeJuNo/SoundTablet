import SwiftUI

/// Waveform with draggable in/out handles. Reports the result on drag end; the model clamps it.
struct TrimEditorView: View {
    let peaks: [Float]
    let duration: Double
    let trimIn: Double
    let trimOut: Double?
    let onChange: (Double, Double?) -> Void

    @State private var dragIn: Double?
    @State private var dragOut: Double?

    var body: some View {
        let inT = dragIn ?? trimIn, outT = dragOut ?? trimOut ?? duration
        VStack(alignment: .leading) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Canvas { ctx, size in
                        let n = max(peaks.count, 1), bw = size.width / CGFloat(n)
                        for (i, p) in peaks.enumerated() {
                            let h = max(1, CGFloat(p) * size.height)
                            ctx.fill(Path(CGRect(x: CGFloat(i) * bw, y: (size.height - h) / 2, width: max(bw - 1, 1), height: h)),
                                     with: .color(.accentColor))
                        }
                    }
                    Rectangle().fill(.black.opacity(0.45)).frame(width: w * inT / max(duration, 0.01))
                    Rectangle().fill(.black.opacity(0.45)).frame(width: w * (1 - outT / max(duration, 0.01)))
                        .offset(x: w * outT / max(duration, 0.01))
                    handle.offset(x: w * inT / max(duration, 0.01) - 8)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                            .onChanged { dragIn = min(max(0, $0.location.x / w * duration), outT - 0.05) }
                            .onEnded { _ in onChange(dragIn ?? trimIn, trimOut); dragIn = nil })
                        .accessibilityLabel("Trim start").accessibilityValue(String(format: "%.2f seconds", inT))
                    handle.offset(x: w * outT / max(duration, 0.01) - 8)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                            .onChanged { dragOut = max(min(duration, $0.location.x / w * duration), inT + 0.05) }
                            .onEnded { _ in onChange(trimIn, dragOut); dragOut = nil })
                        .accessibilityLabel("Trim end").accessibilityValue(String(format: "%.2f seconds", outT))
                }
                .coordinateSpace(name: "trim")
            }
            .frame(height: 80)
            HStack {
                Text(String(format: "In %.2f s", inT)); Spacer(); Text(String(format: "Out %.2f s", outT))
            }.font(.caption.monospacedDigit())
        }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 16, height: 80)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.black.opacity(0.4)))
    }
}
