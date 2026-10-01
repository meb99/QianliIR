import Foundation

/// Vendor command protocol of the InfiRay Tiny1-C / Mini modules, as used by the
/// Windows program's libircmd.dll: commands are written with USB vendor requests
/// (0x41 / 0x45, wValue 0x78) into a register window and the status is polled
/// with 0xC1 / 0x44 at wIndex 0x200.
public enum InfiRayProtocol {
    public static let writeRequestType: UInt8 = 0x41
    public static let writeRequest: UInt8 = 0x45
    public static let readRequestType: UInt8 = 0xC1
    public static let readRequest: UInt8 = 0x44
    public static let value: UInt16 = 0x78
    public static let statusIndex: UInt16 = 0x200
    public static let resultIndex: UInt16 = 0x1D10

    /// Known USB ids (vendor, product).
    public static let knownDevices: [(UInt16, UInt16)] = [(0x0BDA, 0x5840), (0x0BDA, 0x5830)]

    public enum Command: UInt16 {
        case shutterUpdate = 0xC10D        // close shutter once and recalibrate (FFC)
        case setTpdParam = 0xC514           // temperature measurement parameter
        case getTpdParam = 0x8514
    }

    /// Parameters of `setTpdParam`.
    public enum TpdParam: UInt16 {
        case distance = 0        // 1/128 m
        case reflectedTemp = 1   // Kelvin
        case ambientTemp = 2     // Kelvin
        case emissivity = 3      // 1...128 (= ε × 128)
        case transmittance = 4   // 1...128
        case gainSelect = 5      // 1 = high gain (normal range), 0 = low gain (high temperature range)
    }

    /// One control write: wIndex + payload.
    public struct Write: Equatable {
        public let index: UInt16
        public let bytes: [UInt8]
    }

    /// A command without data: 8 bytes at 0x1D00.
    public static func shortCommand(_ cmd: UInt16, param: UInt32 = 0) -> [Write] {
        var b = le16(cmd)
        b += be32(param)
        b += [0, 0]
        return [Write(index: 0x1D00, bytes: b)]
    }

    /// A command with up to three 32-bit arguments and an optional reply length:
    /// 16 bytes written as two 8-byte halves at 0x9D00 and 0x1D08.
    public static func longCommand(_ cmd: UInt16, p1: UInt16, p2: UInt32, p3: UInt32 = 0, replyLength: UInt32 = 0) -> [Write] {
        var b = le16(cmd)
        b += be16(p1)
        b += be32(p2)
        b += be32(p3)
        b += be32(replyLength)
        return [Write(index: 0x9D00, bytes: Array(b[0..<8])), Write(index: 0x1D08, bytes: Array(b[8..<16]))]
    }

    public static func setParam(_ p: TpdParam, _ v: UInt32) -> [Write] {
        longCommand(Command.setTpdParam.rawValue, p1: p.rawValue, p2: v)
    }

    public static func shutter() -> [Write] { shortCommand(Command.shutterUpdate.rawValue) }

    public static func setHighGain(_ high: Bool) -> [Write] { setParam(.gainSelect, high ? 1 : 0) }

    /// Status byte: bit 0/1 = busy, bits 2-7 = error.
    public enum Status { case ready, busy, failed }
    public static func status(_ byte: UInt8) -> Status {
        if byte & 0xFC != 0 { return .failed }
        return byte & 0x03 == 0 ? .ready : .busy
    }

    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }
}

/// Emissivity correction (grey body, Stefan–Boltzmann): the camera assumes ε = 1.
public struct EmissivityCorrection: Equatable {
    public var emissivity: Float
    /// Temperature of the surroundings that the surface reflects (°C).
    public var reflectedTemp: Float

    public init(emissivity: Float, reflectedTemp: Float) {
        self.emissivity = emissivity
        self.reflectedTemp = reflectedTemp
    }

    public var isIdentity: Bool { emissivity >= 0.999 }

    public func correct(_ measured: Float) -> Float {
        guard !isIdentity else { return measured }
        let e = max(0.05, min(1, emissivity))
        let tm = Double(measured) + 273.15
        let tr = Double(reflectedTemp) + 273.15
        let obj4 = (pow(tm, 4) - (1 - Double(e)) * pow(tr, 4)) / Double(e)
        guard obj4 > 0 else { return measured }
        return Float(pow(obj4, 0.25) - 273.15)
    }

    public func apply(to frame: ThermalFrame) -> ThermalFrame {
        guard !isIdentity else { return frame }
        return ThermalFrame(width: frame.width, height: frame.height,
                            celsius: frame.celsius.map(correct), timestamp: frame.timestamp)
    }
}

/// Temperatures sampled along a straight line (the Windows program's "Curve").
public struct LineProfile {
    public var points: [PixelPoint]
    public var temperatures: [Float]

    public init(frame: ThermalFrame, from a: PixelPoint, to b: PixelPoint) {
        let steps = max(abs(b.x - a.x), abs(b.y - a.y))
        var pts = [PixelPoint]()
        var temps = [Float]()
        for i in 0...steps {
            let f = steps == 0 ? 0 : Double(i) / Double(steps)
            let p = PixelPoint(x: Int((Double(a.x) + Double(b.x - a.x) * f).rounded()),
                               y: Int((Double(a.y) + Double(b.y - a.y) * f).rounded()))
            if let t = frame.temperature(at: p) {
                pts.append(p)
                temps.append(t)
            }
        }
        points = pts
        temperatures = temps
    }

    public var maxIndex: Int? { temperatures.indices.max(by: { temperatures[$0] < temperatures[$1] }) }
}
