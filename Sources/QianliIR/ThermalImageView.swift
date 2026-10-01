import SwiftUI
import ThermalCore

/// The live picture. Hover shows the temperature under the mouse; clicking / dragging
/// places measuring points and frames.
struct ThermalImageView: View {
    @EnvironmentObject var model: AppModel
    @State private var dragStart: PixelPoint?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let img = model.image {
                    let fit = fittedRect(CGSize(width: img.width, height: img.height), in: geo.size)
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fit.width, height: fit.height)
                        .position(x: fit.midX, y: fit.midY)
                    hoverLabel(fit: fit)
                } else {
                    placeholder
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): model.hover = sensorPoint(p, in: geo.size, clamp: false)
                case .ended: model.hover = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in dragChanged(v, size: geo.size) }
                    .onEnded { v in dragEnded(v, size: geo.size) }
            )
            .contextMenu {
                Button("Messpunkte und -rahmen löschen") { model.clearMeasurements() }
                Button("Foto speichern") { model.snapshot() }
            }
        }
    }

    @ViewBuilder
    private func hoverLabel(fit: CGRect) -> some View {
        if let h = model.hover, let t = model.temperature(at: h), let f = model.frame, let img = model.image {
            let s = CGFloat(Compositor.scale(for: f))
            let k = fit.width / CGFloat(img.width)
            let x = fit.minX + (CGFloat(h.x) + 0.5) * s * k
            let y = fit.minY + (CGFloat(h.y) + 0.5) * s * k
            Text(model.settings.unit.format(t))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.white)
                .position(x: x + 36, y: y - 14)
                .allowsHitTesting(false)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)
            Text(model.message ?? "Suche Wärmebildkamera …")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            HStack {
                Button("Erneut suchen") {
                    model.refreshCameras()
                    model.autoStart()
                }
                Button("Demo-Modus starten") { model.startDemo() }
            }
        }
        .padding()
    }

    // MARK: - Geometry

    private func fittedRect(_ image: CGSize, in size: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, size.width > 0, size.height > 0 else { return .zero }
        let k = min(size.width / image.width, size.height / image.height)
        let w = image.width * k, h = image.height * k
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func sensorPoint(_ p: CGPoint, in size: CGSize, clamp: Bool) -> PixelPoint? {
        guard let img = model.image, let f = model.frame else { return nil }
        let fit = fittedRect(CGSize(width: img.width, height: img.height), in: size)
        guard fit.width > 0 else { return nil }
        let s = CGFloat(Compositor.scale(for: f))
        let k = CGFloat(img.width) / fit.width
        var x = Int(floor((p.x - fit.minX) * k / s))
        var y = Int(floor((p.y - fit.minY) * k / s))
        if clamp {
            x = min(max(0, x), f.width - 1)
            y = min(max(0, y), f.height - 1)
        }
        let pt = PixelPoint(x: x, y: y)
        return f.contains(pt) ? pt : nil
    }

    private func dragChanged(_ v: DragGesture.Value, size: CGSize) {
        guard model.tool == .rect else { return }
        if dragStart == nil { dragStart = sensorPoint(v.startLocation, in: size, clamp: false) }
        guard let a = dragStart, let b = sensorPoint(v.location, in: size, clamp: true) else { return }
        model.pendingRect = PixelRect(corner: a, b)
    }

    private func dragEnded(_ v: DragGesture.Value, size: CGSize) {
        defer { dragStart = nil }
        switch model.tool {
        case .none:
            break
        case .spot:
            if let p = sensorPoint(v.location, in: size, clamp: false) { model.addSpot(p) }
        case .rect:
            if let r = model.pendingRect { model.addRect(r) }
            model.pendingRect = nil
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(model.isRunning ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(model.sourceName).lineLimit(1)
            if let f = model.frame {
                Text("\(f.width)×\(f.height)").foregroundStyle(.secondary)
            }
            if let h = model.hover, let t = model.temperature(at: h) {
                Text("Maus (\(h.x), \(h.y)): \(model.settings.unit.format(t))").monospacedDigit()
            }
            Spacer()
            if model.isRecording {
                Label(String(format: "REC %02d:%02d", model.recordingSeconds / 60, model.recordingSeconds % 60),
                      systemImage: "record.circle.fill")
                    .foregroundStyle(.red)
                    .monospacedDigit()
            }
            if let msg = model.message, model.image != nil {
                Text(msg).lineLimit(1).foregroundStyle(.secondary)
                Button {
                    model.message = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }
}
