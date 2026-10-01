import XCTest
@testable import ThermalCore

final class ThermalCoreTests: XCTestCase {
    /// Builds a fake 256x384 YUYV frame: grey picture on top, temperatures below.
    private func makeRawFrame(celsius: (Int, Int) -> Float, order: RawByteOrder) -> [UInt8] {
        let w = 256, h = 384
        var data = [UInt8](repeating: 0x80, count: w * h * 2)
        for y in 0..<192 {
            for x in 0..<w {
                let raw = UInt16(((celsius(x, y) + 273.15) * 64).rounded())
                let o = ((192 + y) * w + x) * 2
                let lo = UInt8(raw & 0xFF), hi = UInt8(raw >> 8)
                if order == .yuyv { data[o] = lo; data[o + 1] = hi } else { data[o] = hi; data[o + 1] = lo }
            }
        }
        return data
    }

    func testLayoutDetection() {
        XCTAssertEqual(FrameParser.layout(width: 256, height: 384),
                       FrameLayout(sensorWidth: 256, sensorHeight: 192, temperatureRow: 192))
        XCTAssertEqual(FrameParser.layout(width: 160, height: 240)?.sensorHeight, 120)
        XCTAssertEqual(FrameParser.layout(width: 384, height: 576)?.sensorHeight, 288)
        XCTAssertEqual(FrameParser.layout(width: 256, height: 392)?.temperatureRow, 200)
        XCTAssertNil(FrameParser.layout(width: 1280, height: 720))
        XCTAssertNil(FrameParser.layout(width: 640, height: 480))
        XCTAssertNil(FrameParser.layout(width: 256, height: 192))
    }

    func testParseBothByteOrders() throws {
        for order in [RawByteOrder.yuyv, .uyvy] {
            let data = makeRawFrame(celsius: { x, y in 20 + Float(x) * 0.1 + Float(y) * 0.05 }, order: order)
            let f = try XCTUnwrap(FrameParser.parse(data: data, width: 256, height: 384, order: order))
            XCTAssertEqual(f.width, 256)
            XCTAssertEqual(f.height, 192)
            XCTAssertEqual(f.temperature(at: PixelPoint(x: 0, y: 0))!, 20, accuracy: 0.02)
            XCTAssertEqual(f.temperature(at: PixelPoint(x: 100, y: 50))!, 32.5, accuracy: 0.02)
            XCTAssertTrue(FrameParser.isPlausible(f))
        }
    }

    func testStats() {
        var t = [Float](repeating: 25, count: 16)
        t[5] = 80; t[10] = -3
        let f = ThermalFrame(width: 4, height: 4, celsius: t)
        let s = f.stats()
        XCTAssertEqual(s.max, 80)
        XCTAssertEqual(s.maxPoint, PixelPoint(x: 1, y: 1))
        XCTAssertEqual(s.min, -3)
        XCTAssertEqual(s.minPoint, PixelPoint(x: 2, y: 2))
        let r = f.stats(in: PixelRect(x: 2, y: 0, width: 2, height: 2))
        XCTAssertEqual(r.max, 25)
        XCTAssertEqual(r.mean, 25)
    }

    func testTransforms() {
        // 3x2 frame with values 0...5
        let f = ThermalFrame(width: 3, height: 2, celsius: [0, 1, 2, 3, 4, 5])
        let r90 = f.transformed(rotation: .r90, flipH: false, flipV: false)
        XCTAssertEqual(r90.width, 2); XCTAssertEqual(r90.height, 3)
        XCTAssertEqual(r90.celsius, [3, 0, 4, 1, 5, 2])
        XCTAssertEqual(f.transformed(rotation: .r180, flipH: false, flipV: false).celsius, [5, 4, 3, 2, 1, 0])
        XCTAssertEqual(f.transformed(rotation: .r270, flipH: false, flipV: false).celsius, [2, 5, 1, 4, 0, 3])
        XCTAssertEqual(f.transformed(rotation: .r0, flipH: true, flipV: false).celsius, [2, 1, 0, 5, 4, 3])
        XCTAssertEqual(f.transformed(rotation: .r0, flipH: false, flipV: true).celsius, [3, 4, 5, 0, 1, 2])
    }

    func testRenderAndPalettes() {
        for p in Palette.allCases { XCTAssertEqual(p.lut.count, 256) }
        XCTAssertEqual(Palette.whiteHot.lut[0], RGB(0, 0, 0))
        XCTAssertEqual(Palette.whiteHot.lut[255], RGB(255, 255, 255))

        let frame = DemoScene().frame(at: 1)
        for e in Enhancement.allCases {
            let img = ThermalRenderer.render(frame, options: RenderOptions(palette: .iron, enhancement: e))
            XCTAssertEqual(img.pixels.count, 256 * 192 * 4)
            XCTAssertLessThan(img.rangeLow, img.rangeHigh)
        }
        let fixed = ThermalRenderer.render(frame, options: RenderOptions(palette: .whiteHot, fixedRange: 0...1))
        XCTAssertEqual(fixed.pixels[0], 255) // everything above the range is white
    }

    func testDifference() throws {
        let a = ThermalFrame(width: 2, height: 1, celsius: [30, 30])
        let b = ThermalFrame(width: 2, height: 1, celsius: [30, 40])
        let d = try XCTUnwrap(ThermalRenderer.renderDifference(live: b, reference: a))
        XCTAssertEqual(d.delta.celsius, [0, 10])
        XCTAssertEqual(d.image.pixels[0], 255) // white for no change
        XCTAssertNil(ThermalRenderer.renderDifference(live: a, reference: ThermalFrame(width: 1, height: 1, celsius: [1])))
    }

    func testUnitsAndCSV() {
        XCTAssertEqual(TemperatureUnit.fahrenheit.convert(100), 212)
        XCTAssertEqual(TemperatureUnit.fahrenheit.toCelsius(212), 100, accuracy: 0.001)
        XCTAssertEqual(TemperatureUnit.celsius.format(36.3), "36.3°C")
        let csv = CSVExport.temperatures(ThermalFrame(width: 2, height: 1, celsius: [1.5, 2]), unit: .celsius)
        XCTAssertEqual(csv, "1,50;2,00\n")
    }

    func testProtocolPackets() {
        // Same bytes the Windows libircmd.dll sends for set_prop_tpd_params(GAIN_SEL, 0).
        XCTAssertEqual(InfiRayProtocol.setHighGain(false), [
            .init(index: 0x9D00, bytes: [0x14, 0xC5, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00]),
            .init(index: 0x1D08, bytes: [0, 0, 0, 0, 0, 0, 0, 0]),
        ])
        XCTAssertEqual(InfiRayProtocol.setParam(.emissivity, 0x0102_0304)[0].bytes, [0x14, 0xC5, 0x00, 0x03, 0x01, 0x02, 0x03, 0x04])
        XCTAssertEqual(InfiRayProtocol.shutter(), [.init(index: 0x1D00, bytes: [0x0D, 0xC1, 0, 0, 0, 0, 0, 0])])
        XCTAssertEqual(InfiRayProtocol.status(0), .ready)
        XCTAssertEqual(InfiRayProtocol.status(1), .busy)
        XCTAssertEqual(InfiRayProtocol.status(4), .failed)
    }

    func testEmissivity() {
        let none = EmissivityCorrection(emissivity: 1, reflectedTemp: 25)
        XCTAssertEqual(none.correct(80), 80)
        let c = EmissivityCorrection(emissivity: 0.9, reflectedTemp: 25)
        XCTAssertGreaterThan(c.correct(80), 80)       // a dull surface looks colder than it is
        XCTAssertEqual(c.correct(25), 25, accuracy: 0.01) // at room temperature nothing changes
    }

    func testLineProfile() {
        let f = ThermalFrame(width: 4, height: 1, celsius: [1, 2, 9, 3])
        let p = LineProfile(frame: f, from: PixelPoint(x: 0, y: 0), to: PixelPoint(x: 3, y: 0))
        XCTAssertEqual(p.temperatures, [1, 2, 9, 3])
        XCTAssertEqual(p.maxIndex, 2)
    }
}
