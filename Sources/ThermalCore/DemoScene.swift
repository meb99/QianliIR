import Foundation

/// A simulated circuit board, used when no thermal camera is connected
/// so the program can be tried out.
public struct DemoScene {
    public var width = 256
    public var height = 192

    private struct Blob { var x: Float; var y: Float; var radius: Float; var heat: Float; var sx: Float; var sy: Float }

    private let blobs: [Blob] = [
        Blob(x: 70, y: 60, radius: 14, heat: 18, sx: 1.6, sy: 1.0),   // processor
        Blob(x: 180, y: 50, radius: 9, heat: 9, sx: 1.0, sy: 1.0),     // PMIC
        Blob(x: 200, y: 140, radius: 6, heat: 6, sx: 2.2, sy: 0.6),    // coil
        Blob(x: 110, y: 150, radius: 7, heat: 5, sx: 1.0, sy: 1.4),    // charging IC
    ]

    public init() {}

    public func frame(at time: TimeInterval) -> ThermalFrame {
        var t = [Float](repeating: 0, count: width * height)
        let ambient: Float = 27
        // A shorted capacitor that slowly heats up and cools down again.
        let shortHeat = 25 + 20 * Float(sin(time * 0.4))
        var seed = UInt32(truncatingIfNeeded: Int(time * 25))
        for y in 0..<height {
            for x in 0..<width {
                let fx = Float(x), fy = Float(y)
                var v = ambient + 2 * (fy / Float(height))   // board is a bit warmer at the bottom
                // Copper traces: thin lines slightly warmer.
                if (x % 32 == 5 && y > 20 && y < 170) || (y % 40 == 12 && x > 20 && x < 236) { v += 0.8 }
                for b in blobs {
                    let dx = (fx - b.x) / (b.radius * b.sx), dy = (fy - b.y) / (b.radius * b.sy)
                    v += b.heat * expf(-(dx * dx + dy * dy))
                }
                let dx = fx - 150, dy = fy - 100
                v += shortHeat * expf(-(dx * dx + dy * dy) / 8)
                // Sensor noise.
                seed = seed &* 1_664_525 &+ 1_013_904_223
                v += (Float(seed >> 8 & 0xFFFF) / 65535 - 0.5) * 0.15
                t[y * width + x] = v
            }
        }
        return ThermalFrame(width: width, height: height, celsius: t, timestamp: time)
    }
}

public enum CSVExport {
    /// Temperature matrix with semicolons and decimal commas (opens directly in German Excel / Numbers).
    public static func temperatures(_ frame: ThermalFrame, unit: TemperatureUnit) -> String {
        var s = ""
        s.reserveCapacity(frame.celsius.count * 7)
        for y in 0..<frame.height {
            var row = [String]()
            row.reserveCapacity(frame.width)
            for x in 0..<frame.width {
                let v = unit.convert(frame.celsius[y * frame.width + x])
                row.append(String(format: "%.2f", v).replacingOccurrences(of: ".", with: ","))
            }
            s += row.joined(separator: ";") + "\n"
        }
        return s
    }
}
