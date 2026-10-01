import Foundation

/// Image enhancement modes, as in the Windows program ("Universal", "Image Enhancement", "High Contrast").
public enum Enhancement: String, CaseIterable, Codable, Identifiable {
    case universal, enhanced, highContrast
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .universal: return "Universal"
        case .enhanced: return "Bildverbesserung"
        case .highContrast: return "Hoher Kontrast"
        }
    }
}

public struct RenderOptions {
    public var palette: Palette = .iron
    public var enhancement: Enhancement = .universal
    /// Fixed colour range in °C; nil = automatic (follows the scene).
    public var fixedRange: ClosedRange<Float>? = nil
    /// Quick search: pixels colder than this are drawn in grey, only hotter ones in colour.
    public var isothermThreshold: Float? = nil

    public init(palette: Palette = .iron, enhancement: Enhancement = .universal,
                fixedRange: ClosedRange<Float>? = nil, isothermThreshold: Float? = nil) {
        self.palette = palette
        self.enhancement = enhancement
        self.fixedRange = fixedRange
        self.isothermThreshold = isothermThreshold
    }
}

/// An RGBA8 image (premultiplied, alpha always 255).
public struct RGBAImage {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]
    /// Temperature range (°C) mapped onto the palette.
    public var rangeLow: Float
    public var rangeHigh: Float
}

public enum ThermalRenderer {
    /// Colours a thermal frame.
    public static func render(_ frame: ThermalFrame, options: RenderOptions) -> RGBAImage {
        let n = frame.celsius.count
        var lo: Float, hi: Float
        if let r = options.fixedRange {
            lo = r.lowerBound; hi = r.upperBound
        } else {
            let s = frame.stats()
            lo = s.min; hi = s.max
        }
        if hi - lo < 0.5 { let m = (hi + lo) / 2; lo = m - 0.25; hi = m + 0.25 }

        // Normalised level 0...1 for every pixel.
        var level = [Float](repeating: 0, count: n)
        let span = hi - lo
        frame.celsius.withUnsafeBufferPointer { t in
            for i in 0..<n { level[i] = min(1, max(0, (t[i] - lo) / span)) }
        }

        switch options.enhancement {
        case .universal:
            break
        case .enhanced:
            equalize(&level, amount: 0.5)
        case .highContrast:
            equalize(&level, amount: 1.0)
        }

        let lut = options.palette.lut
        var px = [UInt8](repeating: 255, count: n * 4)
        let threshold = options.isothermThreshold
        frame.celsius.withUnsafeBufferPointer { t in
            for i in 0..<n {
                let o = i * 4
                if let th = threshold, t[i] < th {
                    // Grey, a bit darker so the coloured hot area stands out.
                    let g = UInt8(30 + level[i] * 150)
                    px[o] = g; px[o + 1] = g; px[o + 2] = g
                } else {
                    let c = lut[Int(level[i] * 255)]
                    px[o] = c.r; px[o + 1] = c.g; px[o + 2] = c.b
                }
            }
        }
        return RGBAImage(width: frame.width, height: frame.height, pixels: px, rangeLow: lo, rangeHigh: hi)
    }

    /// Histogram equalisation, blended with the linear mapping by `amount`.
    static func equalize(_ level: inout [Float], amount: Float) {
        let bins = 1024
        var hist = [Int](repeating: 0, count: bins)
        for v in level { hist[min(bins - 1, Int(v * Float(bins - 1)))] += 1 }
        var cdf = [Float](repeating: 0, count: bins)
        var acc = 0
        for i in 0..<bins { acc += hist[i]; cdf[i] = Float(acc) }
        let total = Float(max(1, level.count))
        let first = cdf.first(where: { $0 > 0 }) ?? 0
        let denom = max(1, total - first)
        for i in 0..<level.count {
            let b = min(bins - 1, Int(level[i] * Float(bins - 1)))
            let eq = max(0, (cdf[b] - first) / denom)
            level[i] = level[i] * (1 - amount) + eq * amount
        }
    }

    /// Difference image live − reference: red = warmer than the reference, blue = colder.
    /// Returns nil if the two frames have different sizes.
    public static func renderDifference(live: ThermalFrame, reference: ThermalFrame,
                                        minimumSpan: Float = 2) -> (image: RGBAImage, delta: ThermalFrame)? {
        guard live.width == reference.width, live.height == reference.height else { return nil }
        let n = live.celsius.count
        var d = [Float](repeating: 0, count: n)
        var maxAbs: Float = minimumSpan
        for i in 0..<n {
            d[i] = live.celsius[i] - reference.celsius[i]
            maxAbs = max(maxAbs, abs(d[i]))
        }
        var px = [UInt8](repeating: 255, count: n * 4)
        for i in 0..<n {
            let c = DivergingPalette.color(d[i] / maxAbs)
            px[i * 4] = c.r; px[i * 4 + 1] = c.g; px[i * 4 + 2] = c.b
        }
        let delta = ThermalFrame(width: live.width, height: live.height, celsius: d, timestamp: live.timestamp)
        return (RGBAImage(width: live.width, height: live.height, pixels: px, rangeLow: -maxAbs, rangeHigh: maxAbs), delta)
    }

    /// Colour bar (top = hot) for the legend.
    public static func colorBar(palette: Palette, height: Int) -> RGBAImage {
        let lut = palette.lut
        var px = [UInt8](repeating: 255, count: height * 4)
        for y in 0..<height {
            let c = lut[Int(Float(height - 1 - y) / Float(max(1, height - 1)) * 255)]
            px[y * 4] = c.r; px[y * 4 + 1] = c.g; px[y * 4 + 2] = c.b
        }
        return RGBAImage(width: 1, height: height, pixels: px, rangeLow: 0, rangeHigh: 1)
    }
}
