import XCTest

/// Measures the real text/background contrast of an element from a screenshot.
///
/// The system audit reports "Contrast failed" for iOS 27 glass buttons even when black text sits on an almost white pill
/// (measured 20:1), because it samples through the translucent material. For those system-drawn buttons the audit result
/// is replaced by this measurement, so a genuinely low contrast still fails the test.
@MainActor enum Contrast {
    /// Contrast ratio between the dominant (background) colour and the most distant colour (text) inside `frame` (points).
    static func measure(_ app: XCUIApplication, frame: CGRect) -> Double? {
        guard let cg = app.screenshot().image.cgImage else { return nil }
        let scale = CGFloat(cg.width) / app.windows.firstMatch.frame.width
        let r = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
            .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !r.isEmpty, let crop = cg.cropping(to: r) else { return nil }
        let w = crop.width, h = crop.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        func lin(_ v: UInt8) -> Double { let c = Double(v) / 255; return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let ls = stride(from: 0, to: px.count, by: 4).map { 0.2126 * lin(px[$0]) + 0.7152 * lin(px[$0 + 1]) + 0.0722 * lin(px[$0 + 2]) }.sorted()
        let bg = ls[ls.count / 2]
        let text = abs(ls[ls.count / 100] - bg) > abs(ls[ls.count - 1 - ls.count / 100] - bg) ? ls[ls.count / 100] : ls[ls.count - 1 - ls.count / 100]
        return (max(bg, text) + 0.05) / (min(bg, text) + 0.05)
    }
}
