import AVFoundation
import Foundation
import ThermalCore
import USBControl

/// Sends commands to the thermal camera (temperature range, shutter) over USB,
/// the same way the Windows program's libircmd.dll does.
final class CameraControl {
    private let queue = DispatchQueue(label: "thermal.control")
    private var vendorID: UInt16 = 0
    private var productID: UInt16 = 0

    var isAvailable: Bool { vendorID != 0 }

    /// Remembers which USB device belongs to the selected camera.
    func attach(to device: AVCaptureDevice) {
        if let ids = CameraControl.usbIDs(of: device) {
            vendorID = ids.0; productID = ids.1
        } else if let known = InfiRayProtocol.knownDevices.first(where: { usbctl_present($0.0, $0.1) != 0 }) {
            vendorID = known.0; productID = known.1
        } else {
            vendorID = 0; productID = 0
        }
    }

    func detach() { vendorID = 0; productID = 0 }

    /// "UVC Camera VendorID_3034 ProductID_22592" → (0x0BDA, 0x5840)
    static func usbIDs(of device: AVCaptureDevice) -> (UInt16, UInt16)? {
        let model = device.modelID
        func number(after key: String) -> UInt16? {
            guard let r = model.range(of: key) else { return nil }
            let digits = model[r.upperBound...].prefix(while: { $0.isNumber })
            return UInt16(digits)
        }
        guard let v = number(after: "VendorID_"), let p = number(after: "ProductID_") else { return nil }
        return (v, p)
    }

    func shutter(completion: @escaping (String?) -> Void) {
        send(InfiRayProtocol.shutter(), completion: completion)
    }

    func setHighGain(_ high: Bool, completion: @escaping (String?) -> Void) {
        // After switching the gain the camera needs a fresh shutter calibration.
        send(InfiRayProtocol.setHighGain(high) + InfiRayProtocol.shutter(), completion: completion)
    }

    private func send(_ writes: [InfiRayProtocol.Write], completion: @escaping (String?) -> Void) {
        let vid = vendorID, pid = productID
        guard vid != 0 else {
            completion("Die Kamera nimmt keine Befehle an (USB-Gerät nicht gefunden).")
            return
        }
        queue.async {
            var error: String?
            for w in writes {
                if let e = CameraControl.waitReady(vid, pid) { error = e; break }
                var bytes = w.bytes
                let r = bytes.withUnsafeMutableBytes { buf in
                    usbctl_transfer(vid, pid, InfiRayProtocol.writeRequestType, InfiRayProtocol.writeRequest,
                                    InfiRayProtocol.value, w.index, buf.baseAddress, UInt16(buf.count), 1000)
                }
                if r != 0 {
                    error = "Befehl an die Kamera fehlgeschlagen (Fehler \(String(format: "0x%08X", UInt32(bitPattern: r))))."
                    break
                }
            }
            if error == nil { error = CameraControl.waitReady(vid, pid) }
            DispatchQueue.main.async { completion(error) }
        }
    }

    /// Polls the status register until the camera has processed the last command.
    private static func waitReady(_ vid: UInt16, _ pid: UInt16) -> String? {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            var status: UInt8 = 0
            let r = usbctl_transfer(vid, pid, InfiRayProtocol.readRequestType, InfiRayProtocol.readRequest,
                                    InfiRayProtocol.value, InfiRayProtocol.statusIndex, &status, 1, 1000)
            if r != 0 { return "Kamera antwortet nicht auf Befehle (Fehler \(String(format: "0x%08X", UInt32(bitPattern: r))))." }
            switch InfiRayProtocol.status(status) {
            case .ready: return nil
            case .failed: return "Die Kamera hat den Befehl abgelehnt (Status \(status))."
            case .busy: usleep(10_000)
            }
        }
        return "Zeitüberschreitung beim Warten auf die Kamera."
    }
}
