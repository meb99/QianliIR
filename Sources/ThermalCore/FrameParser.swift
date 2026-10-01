import Foundation

/// Byte order of the 4:2:2 stream as delivered by the operating system.
public enum RawByteOrder {
    /// Y0 U Y1 V – the order the camera sends ('yuvs' on macOS).
    case yuyv
    /// U Y0 V Y1 – byte pairs swapped ('2vuy' on macOS).
    case uyvy
}

/// Where the temperature block sits in an InfiRay-style "image + temperature" frame.
///
/// The Tiny1-C / Mini modules used in QianLi thermal cameras (USB 0BDA:5840, 0BDA:5830)
/// stream one 4:2:2 frame that is twice as tall as the sensor: the upper half is a
/// ready-made grey image, the lower half holds one little-endian 16-bit value per pixel,
/// the temperature in 1/64 Kelvin.
public struct FrameLayout: Equatable {
    public var sensorWidth: Int
    public var sensorHeight: Int
    /// First row (in the full frame) of the temperature block.
    public var temperatureRow: Int

    public init(sensorWidth: Int, sensorHeight: Int, temperatureRow: Int) {
        self.sensorWidth = sensorWidth
        self.sensorHeight = sensorHeight
        self.temperatureRow = temperatureRow
    }
}

public enum FrameParser {
    /// Kelvin * 64 → °C
    @inline(__always)
    public static func celsius(fromRaw raw: UInt16) -> Float {
        Float(raw) / 64 - 273.15
    }

    /// Returns the layout if a capture size looks like an image + temperature frame.
    public static func layout(width w: Int, height h: Int) -> FrameLayout? {
        guard w >= 80, h > w / 2 else { return nil }
        // Known sensor aspect ratios: 4:3 (256x192, 160x120, 384x288) and 5:4 (640x512).
        for sensorH in [w * 3 / 4, w * 4 / 5] where sensorH > 0 {
            if h == 2 * sensorH {
                return FrameLayout(sensorWidth: w, sensorHeight: sensorH, temperatureRow: sensorH)
            }
            // Some firmwares append a few parameter rows; the temperature block is then at the bottom.
            if h > 2 * sensorH && h <= 2 * sensorH + 16 {
                return FrameLayout(sensorWidth: w, sensorHeight: sensorH, temperatureRow: h - sensorH)
            }
        }
        return nil
    }

    /// Reads the temperature block out of a raw frame buffer.
    public static func parse(bytes: UnsafeRawPointer,
                             bytesPerRow: Int,
                             layout: FrameLayout,
                             order: RawByteOrder,
                             timestamp: TimeInterval = 0) -> ThermalFrame {
        let w = layout.sensorWidth, h = layout.sensorHeight
        var out = [Float](repeating: 0, count: w * h)
        let src = bytes.assumingMemoryBound(to: UInt8.self)
        out.withUnsafeMutableBufferPointer { dst in
            for y in 0..<h {
                let row = src + (layout.temperatureRow + y) * bytesPerRow
                for x in 0..<w {
                    let b0 = UInt16(row[2 * x]), b1 = UInt16(row[2 * x + 1])
                    let raw = order == .yuyv ? (b0 | b1 << 8) : (b1 | b0 << 8)
                    dst[y * w + x] = celsius(fromRaw: raw)
                }
            }
        }
        return ThermalFrame(width: w, height: h, celsius: out, timestamp: timestamp)
    }

    /// Convenience for tests and saved raw files.
    public static func parse(data: [UInt8], width: Int, height: Int, order: RawByteOrder) -> ThermalFrame? {
        guard let layout = layout(width: width, height: height), data.count >= width * height * 2 else { return nil }
        return data.withUnsafeBytes { buf in
            parse(bytes: buf.baseAddress!, bytesPerRow: width * 2, layout: layout, order: order)
        }
    }

    /// True if the values look like real temperatures (most pixels between -40 °C and 700 °C).
    /// Used to tell a real temperature stream apart from an ordinary webcam picture.
    public static func isPlausible(_ frame: ThermalFrame) -> Bool {
        let step = max(1, frame.celsius.count / 500)
        var good = 0, total = 0
        var i = 0
        while i < frame.celsius.count {
            let t = frame.celsius[i]
            if t > -40 && t < 700 { good += 1 }
            total += 1
            i += step
        }
        return total > 0 && Double(good) / Double(total) > 0.9
    }
}
