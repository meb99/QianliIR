import AppKit
import AVFoundation
import CoreMedia
import SwiftUI
import ThermalCore
import USBControl

/// Report about cameras and USB devices, so a camera that is not recognised can be analysed.
enum Diagnostics {
    static func report() -> String {
        var lines = [String]()
        let info = Bundle.main.infoDictionary ?? [:]
        lines.append("QianLi IR \(info["CFBundleShortVersionString"] as? String ?? "?") (Build \(info["CFBundleVersion"] as? String ?? "?"))")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Kamerazugriff: \(permission)")
        lines.append("")

        let devices = CameraDirectory.videoDevices()
        lines.append("== Kameras (\(devices.count)) ==")
        if devices.isEmpty { lines.append("keine") }
        for d in devices {
            lines.append("• \(d.localizedName)")
            lines.append("  Modell: \(d.modelID)   Hersteller: \(d.manufacturer)")
            lines.append("  ID: \(d.uniqueID)   Typ: \(d.deviceType.rawValue)")
            if let t = CameraDirectory.thermalFormat(for: d) {
                lines.append("  → Wärmebild erkannt: \(t.layout.sensorWidth)×\(t.layout.sensorHeight), Temperaturen ab Zeile \(t.layout.temperatureRow)")
            } else {
                lines.append("  → kein bekanntes Wärmebild-Format")
            }
            var seen = Set<String>()
            for f in d.formats {
                let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                let sub = fourCC(CMFormatDescriptionGetMediaSubType(f.formatDescription))
                let fps = f.videoSupportedFrameRateRanges.map { String(format: "%.0f", $0.maxFrameRate) }.joined(separator: "/")
                let line = "    \(sub)  \(dims.width)×\(dims.height)  \(fps) fps"
                if seen.insert(line).inserted { lines.append(line) }
            }
        }
        lines.append("")

        var buf = [CChar](repeating: 0, count: 16_384)
        let n = usbctl_list(&buf, Int32(buf.count))
        lines.append("== USB-Geräte (\(n)) ==")
        lines.append(String(cString: buf))
        return lines.joined(separator: "\n")
    }

    private static var permission: String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return "erlaubt"
        case .denied: return "VERWEIGERT"
        case .restricted: return "eingeschränkt"
        case .notDetermined: return "noch nicht gefragt"
        @unknown default: return "unbekannt"
        }
    }

    static func fourCC(_ v: FourCharCode) -> String {
        let bytes = [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }), let s = String(bytes: bytes, encoding: .ascii) { return "'\(s)'" }
        return String(format: "0x%08X", v)
    }
}

struct DiagnosticsWindow: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Wenn die Wärmebildkamera nicht erkannt wird: Kamera anschließen, „Aktualisieren“ klicken und den Text kopieren und schicken.")
                .font(.callout)
                .padding(10)
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            HStack {
                Button("Aktualisieren") { refresh() }
                Spacer()
                if copied { Text("Kopiert ✓").foregroundStyle(.green) }
                Button("Text kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(10)
            .background(.bar)
        }
        .frame(minWidth: 620, minHeight: 460)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        model.refreshCameras()
        text = Diagnostics.report()
        copied = false
    }
}
