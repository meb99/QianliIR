import AppKit
import CoreGraphics
import CoreImage
import ThermalCore

enum ImageUtil {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func cgImage(_ img: RGBAImage) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(img.pixels) as CFData) else { return nil }
        return CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: img.width * 4, space: sRGB,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func pngData(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }
}

/// Everything that goes into one displayed picture.
struct CompositeInput {
    var frame: ThermalFrame
    var rendered: RGBAImage
    var stats: TemperatureStats
    var settings: AppSettings
    var spots: [PixelPoint]
    var rects: [PixelRect]
    var pendingRect: PixelRect?
    var visible: CGImage?
    var alarm: Bool
}

/// Draws the coloured thermal image, the dual-light fusion, the measurement markers
/// and the colour bar into one picture. The same picture is shown, saved and recorded.
final class Compositor {
    static let barWidth = 78

    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Upscaling factor from sensor pixels to picture pixels.
    static func scale(for frame: ThermalFrame) -> Int {
        max(1, Int((768.0 / Double(max(frame.width, frame.height))).rounded()))
    }

    func compose(_ input: CompositeInput) -> CGImage? {
        let s = Compositor.scale(for: input.frame)
        let W = input.frame.width * s, H = input.frame.height * s
        let totalW = W + Compositor.barWidth
        guard let ctx = CGContext(data: nil, width: totalW, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: ImageUtil.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: totalW, height: H))

        let thermalRect = CGRect(x: 0, y: 0, width: W, height: H)
        drawImages(input, in: ctx, rect: thermalRect, scale: s)

        // Overlays use a top-left origin like the sensor coordinates.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(H))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        drawOverlays(input, in: ctx, scale: s, size: CGSize(width: W, height: H))
        drawColorBar(input, in: ctx, x: CGFloat(W), height: CGFloat(H))
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
        return ctx.makeImage()
    }

    // MARK: - Images

    private func drawImages(_ input: CompositeInput, in ctx: CGContext, rect: CGRect, scale s: Int) {
        let st = input.settings
        guard let ir = thermalImage(input.rendered, scale: s, smooth: st.superResolution) else { return }
        ctx.interpolationQuality = st.superResolution ? .high : .none

        let visible = input.visible
        switch (st.fusionMode, visible) {
        case (.thermal, _), (_, nil):
            ctx.draw(ir, in: rect)
        case (.visible, let v?):
            drawVisible(v, in: ctx, rect: rect, settings: st, gray: false)
        case (.blend, let v?):
            drawVisible(v, in: ctx, rect: rect, settings: st, gray: false)
            ctx.saveGState()
            ctx.setAlpha(CGFloat(1 - st.fusionWeight))
            ctx.draw(ir, in: rect)
            ctx.restoreGState()
        case (.detail, let v?):
            ctx.draw(ir, in: rect)
            ctx.saveGState()
            ctx.setBlendMode(.overlay)
            ctx.setAlpha(CGFloat(st.fusionWeight))
            drawVisible(v, in: ctx, rect: rect, settings: st, gray: true)
            ctx.restoreGState()
        }
    }

    private func thermalImage(_ rendered: RGBAImage, scale s: Int, smooth: Bool) -> CGImage? {
        guard let base = ImageUtil.cgImage(rendered) else { return nil }
        guard smooth, s > 1 else { return base }
        // "Super resolution": Lanczos upscaling plus a little sharpening.
        let target = CGRect(x: 0, y: 0, width: rendered.width * s, height: rendered.height * s)
        let ci = CIImage(cgImage: base)
            .clampedToExtent()
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
            .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.4])
            .cropped(to: target)
        return ciContext.createCGImage(ci, from: target) ?? base
    }

    private func drawVisible(_ v: CGImage, in ctx: CGContext, rect: CGRect, settings st: AppSettings, gray: Bool) {
        var img = v
        if gray, let g = grayscale(v) { img = g }
        // Aspect-fill the thermal area, then apply the manual alignment.
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let fill = max(rect.width / iw, rect.height / ih) * CGFloat(st.alignScale)
        let w = iw * fill, h = ih * fill
        let x = rect.midX - w / 2 + CGFloat(st.alignOffsetX) * rect.width
        let y = rect.midY - h / 2 - CGFloat(st.alignOffsetY) * rect.height
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: x, y: y, width: w, height: h))
        ctx.restoreGState()
    }

    private func grayscale(_ image: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: image).applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0, kCIInputContrastKey: 1.6,
        ])
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    // MARK: - Overlays

    private func drawOverlays(_ input: CompositeInput, in ctx: CGContext, scale s: Int, size: CGSize) {
        let st = input.settings
        let f = input.frame
        let fontSize = max(11, size.height / 42)
        func pt(_ p: PixelPoint) -> CGPoint { CGPoint(x: (CGFloat(p.x) + 0.5) * CGFloat(s), y: (CGFloat(p.y) + 0.5) * CGFloat(s)) }
        func fmt(_ c: Float) -> String { st.unit.format(c) }

        if st.quickSearch {
            let c = pt(input.stats.maxPoint)
            ctx.setStrokeColor(NSColor.systemOrange.cgColor)
            ctx.setLineWidth(3)
            for r in [CGFloat(14), 24] {
                ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            }
        }

        if st.showCenter, let t = f.temperature(at: f.center) {
            let c = pt(f.center)
            drawCross(ctx, at: c, color: .white, size: fontSize)
            drawLabel(fmt(t), at: CGPoint(x: c.x + fontSize, y: c.y - fontSize * 1.6), color: .white, fontSize: fontSize, bounds: size)
        }
        if st.trackMax {
            let c = pt(input.stats.maxPoint)
            drawCross(ctx, at: c, color: .systemRed, size: fontSize)
            drawLabel("▲ " + fmt(input.stats.max), at: CGPoint(x: c.x + fontSize, y: c.y + 2), color: .systemRed, fontSize: fontSize, bounds: size)
        }
        if st.trackMin {
            let c = pt(input.stats.minPoint)
            drawCross(ctx, at: c, color: .systemBlue, size: fontSize)
            drawLabel("▼ " + fmt(input.stats.min), at: CGPoint(x: c.x + fontSize, y: c.y + 2), color: .systemBlue, fontSize: fontSize, bounds: size)
        }

        for (i, p) in input.spots.enumerated() {
            guard let t = f.temperature(at: p) else { continue }
            let c = pt(p)
            ctx.setStrokeColor(NSColor.systemGreen.cgColor)
            ctx.setLineWidth(2)
            let r = fontSize * 0.5
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.fillEllipse(in: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3))
            drawLabel("P\(i + 1)  " + fmt(t), at: CGPoint(x: c.x + r + 3, y: c.y - fontSize * 0.7), color: .systemGreen, fontSize: fontSize, bounds: size)
        }

        var allRects = input.rects.enumerated().map { ("R\($0.offset + 1)", $0.element, NSColor.systemYellow) }
        if let p = input.pendingRect { allRects.append(("", p, NSColor.white)) }
        for (name, r, color) in allRects {
            guard let rr = r.clamped(width: f.width, height: f.height) else { continue }
            let box = CGRect(x: CGFloat(rr.x * s), y: CGFloat(rr.y * s), width: CGFloat(rr.width * s), height: CGFloat(rr.height * s))
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(box)
            guard !name.isEmpty else { continue }
            let rs = f.stats(in: rr)
            let mp = pt(rs.maxPoint)
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: mp.x - 2, y: mp.y - 2, width: 4, height: 4))
            let text = "\(name)  ▲\(fmt(rs.max))  ▼\(fmt(rs.min))  Ø\(fmt(rs.mean))"
            drawLabel(text, at: CGPoint(x: box.minX, y: box.minY - fontSize * 1.6), color: color, fontSize: fontSize * 0.9, bounds: size)
        }

        if input.alarm {
            ctx.setStrokeColor(NSColor.systemRed.cgColor)
            ctx.setLineWidth(8)
            ctx.stroke(CGRect(x: 4, y: 4, width: size.width - 8, height: size.height - 8))
            drawLabel("ALARM  ≥ " + fmt(st.alarmThreshold), at: CGPoint(x: 14, y: 14), color: .white,
                      fontSize: fontSize * 1.2, bounds: size, background: NSColor.systemRed)
        }
    }

    private func drawCross(_ ctx: CGContext, at c: CGPoint, color: NSColor, size: CGFloat) {
        let a = size * 0.8
        ctx.setLineWidth(3)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        strokeCross(ctx, c, a)
        ctx.setLineWidth(1.5)
        ctx.setStrokeColor(color.cgColor)
        strokeCross(ctx, c, a)
    }

    private func strokeCross(_ ctx: CGContext, _ c: CGPoint, _ a: CGFloat) {
        ctx.beginPath()
        ctx.move(to: CGPoint(x: c.x - a, y: c.y)); ctx.addLine(to: CGPoint(x: c.x - 3, y: c.y))
        ctx.move(to: CGPoint(x: c.x + 3, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + a, y: c.y))
        ctx.move(to: CGPoint(x: c.x, y: c.y - a)); ctx.addLine(to: CGPoint(x: c.x, y: c.y - 3))
        ctx.move(to: CGPoint(x: c.x, y: c.y + 3)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + a))
        ctx.strokePath()
    }

    private func drawLabel(_ text: String, at p: CGPoint, color: NSColor, fontSize: CGFloat, bounds: CGSize,
                           background: NSColor = NSColor.black.withAlphaComponent(0.55)) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: color,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let sz = str.size()
        // Keep labels inside the picture.
        let x = min(max(2, p.x), bounds.width - sz.width - 6)
        let y = min(max(2, p.y), bounds.height - sz.height - 4)
        let bg = CGRect(x: x - 3, y: y - 1, width: sz.width + 6, height: sz.height + 2)
        background.setFill()
        NSBezierPath(roundedRect: bg, xRadius: 3, yRadius: 3).fill()
        str.draw(at: CGPoint(x: x, y: y))
    }

    private func drawColorBar(_ input: CompositeInput, in ctx: CGContext, x: CGFloat, height H: CGFloat) {
        let st = input.settings
        let fontSize = max(10, H / 50)
        let top = fontSize * 2.4, bottom = H - fontSize * 2.4
        let barRect = CGRect(x: x + 10, y: top, width: 18, height: bottom - top)
        if let bar = ImageUtil.cgImage(ThermalRenderer.colorBar(palette: st.palette, height: 256)) {
            ctx.saveGState()
            // Undo the flip for the image so hot is at the top.
            ctx.translateBy(x: 0, y: barRect.maxY + barRect.minY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(bar, in: barRect)
            ctx.restoreGState()
        }
        ctx.setStrokeColor(NSColor(white: 0.7, alpha: 1).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(barRect)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let lo = input.rendered.rangeLow, hi = input.rendered.rangeHigh
        func label(_ v: Float, _ y: CGFloat) {
            let s = NSAttributedString(string: String(format: "%.1f", st.unit.convert(v)), attributes: attrs)
            s.draw(at: CGPoint(x: x + 32, y: y - s.size().height / 2))
        }
        for i in 0...4 {
            let f = Float(i) / 4
            label(hi - (hi - lo) * f, top + (bottom - top) * CGFloat(f))
        }
        let unit = NSAttributedString(string: st.unit.symbol + (st.autoRange ? "  auto" : ""), attributes: attrs)
        unit.draw(at: CGPoint(x: x + 8, y: 4))
    }
}
