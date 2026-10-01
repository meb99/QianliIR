import Foundation

public struct PixelPoint: Hashable, Codable {
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

public struct PixelRect: Hashable, Codable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// Rectangle spanned by two corner points (inclusive), in any order.
    public init(corner a: PixelPoint, _ b: PixelPoint) {
        x = min(a.x, b.x)
        y = min(a.y, b.y)
        width = abs(a.x - b.x) + 1
        height = abs(a.y - b.y) + 1
    }

    public func clamped(width w: Int, height h: Int) -> PixelRect? {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(w, x + width), y1 = min(h, y + height)
        guard x1 > x0, y1 > y0 else { return nil }
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

public struct TemperatureStats: Equatable {
    public var min: Float
    public var max: Float
    public var mean: Float
    public var minPoint: PixelPoint
    public var maxPoint: PixelPoint
}

public enum Rotation: Int, CaseIterable, Codable {
    case r0 = 0, r90 = 90, r180 = 180, r270 = 270

    public var next: Rotation {
        switch self {
        case .r0: return .r90
        case .r90: return .r180
        case .r180: return .r270
        case .r270: return .r0
        }
    }
}

/// One thermal image: a temperature in °C for every sensor pixel, row-major.
public struct ThermalFrame {
    public let width: Int
    public let height: Int
    public var celsius: [Float]
    public var timestamp: TimeInterval

    public init(width: Int, height: Int, celsius: [Float], timestamp: TimeInterval = 0) {
        precondition(celsius.count == width * height, "temperature count does not match size")
        self.width = width
        self.height = height
        self.celsius = celsius
        self.timestamp = timestamp
    }

    public func contains(_ p: PixelPoint) -> Bool {
        p.x >= 0 && p.y >= 0 && p.x < width && p.y < height
    }

    public func temperature(at p: PixelPoint) -> Float? {
        guard contains(p) else { return nil }
        return celsius[p.y * width + p.x]
    }

    public var center: PixelPoint { PixelPoint(x: width / 2, y: height / 2) }

    /// Min / max / mean over the whole frame, or over `rect` if given.
    public func stats(in rect: PixelRect? = nil) -> TemperatureStats {
        let r = (rect ?? PixelRect(x: 0, y: 0, width: width, height: height)).clamped(width: width, height: height)
            ?? PixelRect(x: 0, y: 0, width: width, height: height)
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        var loP = PixelPoint(x: r.x, y: r.y), hiP = loP
        var sum: Double = 0
        celsius.withUnsafeBufferPointer { t in
            for y in r.y..<(r.y + r.height) {
                let row = y * width
                for x in r.x..<(r.x + r.width) {
                    let v = t[row + x]
                    sum += Double(v)
                    if v < lo { lo = v; loP = PixelPoint(x: x, y: y) }
                    if v > hi { hi = v; hiP = PixelPoint(x: x, y: y) }
                }
            }
        }
        let n = Double(r.width * r.height)
        return TemperatureStats(min: lo, max: hi, mean: Float(sum / n), minPoint: loP, maxPoint: hiP)
    }

    /// Adds a constant correction to every pixel.
    public func offset(by delta: Float) -> ThermalFrame {
        guard delta != 0 else { return self }
        return ThermalFrame(width: width, height: height, celsius: celsius.map { $0 + delta }, timestamp: timestamp)
    }

    /// Mirrors first, then rotates clockwise.
    public func transformed(rotation: Rotation, flipH: Bool, flipV: Bool) -> ThermalFrame {
        if rotation == .r0 && !flipH && !flipV { return self }
        let w = width, h = height
        let nw = (rotation == .r90 || rotation == .r270) ? h : w
        let nh = (rotation == .r90 || rotation == .r270) ? w : h
        var out = [Float](repeating: 0, count: w * h)
        celsius.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for ny in 0..<nh {
                    for nx in 0..<nw {
                        // Position in the mirrored source image.
                        var sx: Int, sy: Int
                        switch rotation {
                        case .r0: sx = nx; sy = ny
                        case .r90: sx = ny; sy = h - 1 - nx
                        case .r180: sx = w - 1 - nx; sy = h - 1 - ny
                        case .r270: sx = w - 1 - ny; sy = nx
                        }
                        if flipH { sx = w - 1 - sx }
                        if flipV { sy = h - 1 - sy }
                        dst[ny * nw + nx] = src[sy * w + sx]
                    }
                }
            }
        }
        return ThermalFrame(width: nw, height: nh, celsius: out, timestamp: timestamp)
    }
}

public enum TemperatureUnit: String, CaseIterable, Codable {
    case celsius, fahrenheit

    public var symbol: String { self == .celsius ? "°C" : "°F" }

    public func convert(_ c: Float) -> Float { self == .celsius ? c : c * 9 / 5 + 32 }

    /// Converts a temperature *difference*.
    public func convertDelta(_ d: Float) -> Float { self == .celsius ? d : d * 9 / 5 }

    /// Converts a value entered in this unit back to °C.
    public func toCelsius(_ v: Float) -> Float { self == .celsius ? v : (v - 32) * 5 / 9 }

    public func format(_ c: Float, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f", convert(c)) + symbol
    }
}
