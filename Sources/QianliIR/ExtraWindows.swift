import Charts
import SceneKit
import SwiftUI
import ThermalCore

// MARK: - 3D

/// Temperature as a height map ("2D/3D" in the Windows program).
struct Thermal3DWindow: View {
    @EnvironmentObject var model: AppModel
    @State private var heightScale = 0.35

    var body: some View {
        VStack(spacing: 0) {
            if let f = model.frame {
                Thermal3DView(frame: f, palette: model.settings.palette, heightScale: heightScale)
            } else {
                Text("Kein Bild").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Text("Höhe")
                Slider(value: $heightScale, in: 0.05...1).frame(maxWidth: 220)
                Spacer()
                Text("Ziehen = drehen, Scrollen = zoomen").foregroundStyle(.secondary)
            }
            .padding(8)
            .background(.bar)
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

struct Thermal3DView: NSViewRepresentable {
    let frame: ThermalFrame
    let palette: Palette
    let heightScale: Double

    final class Coordinator {
        let scene = SCNScene()
        let surface = SCNNode()
        var lastUpdate = Date.distantPast
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        let c = context.coordinator
        view.scene = c.scene
        view.backgroundColor = .black
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling4X
        c.scene.rootNode.addChildNode(c.surface)
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.zFar = 2000
        cam.position = SCNVector3(0, 150, 170)
        cam.look(at: SCNVector3(0, 0, 0))
        c.scene.rootNode.addChildNode(cam)
        view.pointOfView = cam
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let c = context.coordinator
        // Rebuilding the mesh ~8 times per second is plenty.
        guard Date().timeIntervalSince(c.lastUpdate) > 0.12 else { return }
        c.lastUpdate = Date()
        c.surface.geometry = makeGeometry()
    }

    private func makeGeometry() -> SCNGeometry {
        let step = max(1, frame.width / 128)
        let gx = frame.width / step, gy = frame.height / step
        let s = frame.stats()
        let span = max(0.5, s.max - s.min)
        let lut = palette.lut
        let size: CGFloat = 200
        let cell = size / CGFloat(max(gx, gy))
        let maxHeight = CGFloat(heightScale) * size * 0.5

        var verts = [SCNVector3]()
        var colors = [SIMD4<Float>]()
        verts.reserveCapacity(gx * gy)
        colors.reserveCapacity(gx * gy)
        for y in 0..<gy {
            for x in 0..<gx {
                let t = frame.celsius[(y * step) * frame.width + x * step]
                let level = min(1, max(0, (t - s.min) / span))
                verts.append(SCNVector3((CGFloat(x) - CGFloat(gx) / 2) * cell,
                                        CGFloat(level) * maxHeight,
                                        (CGFloat(y) - CGFloat(gy) / 2) * cell))
                let col = lut[Int(level * 255)]
                colors.append(SIMD4<Float>(Float(col.r) / 255, Float(col.g) / 255, Float(col.b) / 255, 1))
            }
        }
        var idx = [UInt32]()
        idx.reserveCapacity((gx - 1) * (gy - 1) * 6)
        for y in 0..<(gy - 1) {
            for x in 0..<(gx - 1) {
                let a = UInt32(y * gx + x), b = a + 1, c = a + UInt32(gx), d = c + 1
                idx += [a, c, b, b, c, d]
            }
        }
        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors.count,
                                            usesFloatComponents: true, componentsPerVector: 4,
                                            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                            dataStride: MemoryLayout<SIMD4<Float>>.stride)
        let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: verts), colorSource],
                              elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor.white
        m.isDoubleSided = true
        geo.materials = [m]
        return geo
    }
}

// MARK: - Comparison

/// Good board vs. faulty board: store a reference picture, then compare live against it.
struct CompareWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                panel("Referenz (gute Platine)", image: referenceImage)
                panel("Live", image: liveImage)
                panel("Unterschied  (rot = wärmer, blau = kälter)", image: diff?.image)
            }
            .padding(8)
            HStack {
                Button {
                    model.captureReference()
                } label: {
                    Label("Aktuelles Bild als Referenz", systemImage: "square.and.arrow.down")
                }
                .disabled(model.frame == nil)
                Button("Referenz löschen") { model.reference = nil }
                    .disabled(model.reference == nil)
                Spacer()
                if let d = diff {
                    let s = d.delta.stats()
                    Text("größte Erwärmung: \(signed(s.max))   größte Abkühlung: \(signed(s.min))")
                        .monospacedDigit()
                } else if model.reference != nil {
                    Text("Referenz hat eine andere Bildgröße (Drehung?).").foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(.bar)
        }
        .frame(minWidth: 820, minHeight: 360)
    }

    private func signed(_ v: Float) -> String {
        let u = model.settings.unit
        return String(format: "%+.1f", u.convertDelta(v)) + u.symbol
    }

    /// Common colour range so reference and live picture are comparable.
    private var options: RenderOptions {
        var lo = model.stats?.min ?? 0, hi = model.stats?.max ?? 1
        if let r = model.reference {
            let s = r.stats()
            lo = min(lo, s.min); hi = max(hi, s.max)
        }
        return RenderOptions(palette: model.settings.palette, fixedRange: lo...max(hi, lo + 0.5))
    }

    private var referenceImage: CGImage? {
        model.reference.flatMap { ImageUtil.cgImage(ThermalRenderer.render($0, options: options)) }
    }

    private var liveImage: CGImage? {
        model.frame.flatMap { ImageUtil.cgImage(ThermalRenderer.render($0, options: options)) }
    }

    private var diff: (image: CGImage?, delta: ThermalFrame)? {
        guard let live = model.frame, let ref = model.reference,
              let d = ThermalRenderer.renderDifference(live: live, reference: ref) else { return nil }
        return (ImageUtil.cgImage(d.image), d.delta)
    }

    private func panel(_ title: String, image: CGImage?) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ZStack {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else {
                    Text("–").foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - History

/// Temperature over time.
struct HistoryWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let u = model.settings.unit
        VStack(spacing: 0) {
            Chart {
                ForEach(model.history.suffix(900)) { h in
                    LineMark(x: .value("Zeit", h.time), y: .value("Temperatur", u.convert(h.max)),
                             series: .value("Kurve", "Max"))
                        .foregroundStyle(.red)
                    LineMark(x: .value("Zeit", h.time), y: .value("Temperatur", u.convert(h.min)),
                             series: .value("Kurve", "Min"))
                        .foregroundStyle(.blue)
                    LineMark(x: .value("Zeit", h.time), y: .value("Temperatur", u.convert(h.center)),
                             series: .value("Kurve", "Mitte"))
                        .foregroundStyle(.gray)
                }
            }
            .chartYAxisLabel(u.symbol)
            .chartYScale(domain: .automatic(includesZero: false))
            .padding()
            HStack {
                Label("Max", systemImage: "circle.fill").foregroundStyle(.red)
                Label("Min", systemImage: "circle.fill").foregroundStyle(.blue)
                Label("Mitte", systemImage: "circle.fill").foregroundStyle(.gray)
                Spacer()
                Toggle("Pause", isOn: $model.historyPaused)
                Button("Leeren") { model.clearHistory() }
                Button("Als CSV speichern") { model.exportHistory() }
                    .disabled(model.history.isEmpty)
            }
            .font(.callout)
            .padding(8)
            .background(.bar)
        }
        .frame(minWidth: 600, minHeight: 320)
    }
}
