import Foundation

public struct RGB: Equatable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
}

/// The six colour palettes (the Windows program also offers six).
public enum Palette: Int, CaseIterable, Codable, Identifiable {
    case iron = 1, rainbow, whiteHot, blackHot, lava, arctic

    public var id: Int { rawValue }

    public var name: String {
        switch self {
        case .iron: return "Eisen"
        case .rainbow: return "Regenbogen"
        case .whiteHot: return "Weiß heiß"
        case .blackHot: return "Schwarz heiß"
        case .lava: return "Lava"
        case .arctic: return "Arktis"
        }
    }

    private var stops: [(Double, RGB)] {
        switch self {
        case .iron:
            return [(0, RGB(0, 0, 0)), (0.12, RGB(30, 0, 90)), (0.3, RGB(130, 0, 150)),
                    (0.5, RGB(215, 40, 70)), (0.68, RGB(245, 110, 0)), (0.85, RGB(255, 200, 20)),
                    (1, RGB(255, 255, 230))]
        case .rainbow:
            return [(0, RGB(20, 0, 80)), (0.15, RGB(0, 40, 255)), (0.35, RGB(0, 220, 255)),
                    (0.5, RGB(0, 230, 70)), (0.65, RGB(255, 255, 0)), (0.82, RGB(255, 110, 0)),
                    (0.95, RGB(255, 0, 0)), (1, RGB(255, 255, 255))]
        case .whiteHot:
            return [(0, RGB(0, 0, 0)), (1, RGB(255, 255, 255))]
        case .blackHot:
            return [(0, RGB(255, 255, 255)), (1, RGB(0, 0, 0))]
        case .lava:
            return [(0, RGB(0, 0, 0)), (0.25, RGB(90, 0, 0)), (0.5, RGB(200, 30, 0)),
                    (0.75, RGB(255, 140, 0)), (0.9, RGB(255, 230, 110)), (1, RGB(255, 255, 255))]
        case .arctic:
            return [(0, RGB(0, 0, 40)), (0.25, RGB(0, 60, 160)), (0.5, RGB(0, 180, 220)),
                    (0.65, RGB(200, 240, 255)), (0.8, RGB(255, 200, 0)), (1, RGB(255, 40, 0))]
        }
    }

    /// 256-entry lookup table.
    public var lut: [RGB] { Palette.cache[self]! }

    private static let cache: [Palette: [RGB]] = {
        var d = [Palette: [RGB]]()
        for p in Palette.allCases { d[p] = p.buildLUT() }
        return d
    }()

    private func buildLUT() -> [RGB] {
        let s = stops
        var table = [RGB]()
        table.reserveCapacity(256)
        for i in 0..<256 {
            let t = Double(i) / 255
            var k = 0
            while k < s.count - 2 && t > s[k + 1].0 { k += 1 }
            let (t0, c0) = s[k], (t1, c1) = s[k + 1]
            let f = t1 > t0 ? min(1, max(0, (t - t0) / (t1 - t0))) : 0
            func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) + (Double(b) - Double(a)) * f).rounded()) }
            table.append(RGB(mix(c0.r, c1.r), mix(c0.g, c1.g), mix(c0.b, c1.b)))
        }
        return table
    }
}

/// Blue – white – red, for difference images (colder / equal / warmer).
public enum DivergingPalette {
    public static func color(_ v: Float) -> RGB {
        // v in -1...1
        let t = max(-1, min(1, v))
        if t < 0 {
            let f = -t
            return RGB(UInt8(255 * (1 - f)), UInt8(255 * (1 - 0.6 * f)), 255)
        } else {
            let f = t
            return RGB(255, UInt8(255 * (1 - 0.8 * f)), UInt8(255 * (1 - f)))
        }
    }
}
