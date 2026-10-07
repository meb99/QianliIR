import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ThermalCore

struct CameraInfo: Identifiable, Hashable {
    let id: String
    let name: String
    /// Set if the camera offers an "image + temperature" format (InfiRay Tiny / Mini).
    let thermalSize: String?
}

enum CameraDirectory {
    static func videoDevices() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types.append(.external)
        } else {
            types.append(.externalUnknown)
        }
        var devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        // The older API also lists unusual devices the discovery session may skip.
        for d in AVCaptureDevice.devices(for: .video) where !devices.contains(where: { $0.uniqueID == d.uniqueID }) {
            devices.append(d)
        }
        return devices
    }

    static func cameras() -> [CameraInfo] {
        videoDevices().map { d in
            let size = thermalFormat(for: d).map { "\($0.layout.sensorWidth)×\($0.layout.sensorHeight)" }
            return CameraInfo(id: d.uniqueID, name: d.localizedName, thermalSize: size)
        }
    }

    /// The capture format that carries temperatures, if the device has one.
    static func thermalFormat(for device: AVCaptureDevice) -> (format: AVCaptureDevice.Format, layout: FrameLayout)? {
        for f in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            guard sub == kCVPixelFormatType_422YpCbCr8_yuvs || sub == kCVPixelFormatType_422YpCbCr8 else { continue }
            if let layout = FrameParser.layout(width: Int(dims.width), height: Int(dims.height)) {
                return (f, layout)
            }
        }
        return nil
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}

enum CaptureError: LocalizedError {
    case deviceNotFound
    case noThermalFormat(String)
    case cannotAddInput(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound: return "Kamera nicht gefunden."
        case .noThermalFormat(let name): return "„\(name)“ liefert keine Temperaturdaten (kein InfiRay-Tiny/Mini-Format)."
        case .cannotAddInput(let msg): return "Kamera kann nicht geöffnet werden: \(msg)"
        }
    }
}

/// Streams temperature frames from a QianLi / InfiRay thermal camera via the standard macOS
/// video interface (no driver needed on the Mac).
final class ThermalCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "thermal.capture")
    private var layout: FrameLayout?
    private let busyLock = NSLock()
    private var busy = false

    /// Called on the main thread with every new frame (frames are dropped while the previous one is still being shown).
    var onFrame: ((ThermalFrame) -> Void)?
    var onProblem: ((String) -> Void)?

    private(set) var deviceName = ""

    func start(deviceID: String) throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else { throw CaptureError.deviceNotFound }
        guard let found = CameraDirectory.thermalFormat(for: device) else {
            throw CaptureError.noThermalFormat(device.localizedName)
        }
        let format = found.format, layout = found.layout
        self.layout = layout
        deviceName = device.localizedName

        session.beginConfiguration()
        for i in session.inputs { session.removeInput(i) }
        for o in session.outputs { session.removeOutput(o) }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CaptureError.cannotAddInput("Eingang belegt") }
            session.addInput(input)
        } catch let e as CaptureError {
            session.commitConfiguration(); throw e
        } catch {
            session.commitConfiguration(); throw CaptureError.cannotAddInput(error.localizedDescription)
        }

        let output = AVCaptureVideoDataOutput()
        // Ask for the camera's own 4:2:2 byte layout so the 16-bit temperature values pass through unchanged.
        let native = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        let wanted: OSType = output.availableVideoPixelFormatTypes.contains(native) ? native : kCVPixelFormatType_422YpCbCr8_yuvs
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: wanted,
            kCVPixelBufferWidthKey as String: Int(dims.width),
            kCVPixelBufferHeightKey as String: Int(dims.height),
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.unlockForConfiguration()
        } catch {
            onProblem?("Format konnte nicht gesetzt werden: \(error.localizedDescription)")
        }
        session.commitConfiguration()
        queue.async { [session] in session.startRunning() }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        busyLock.lock()
        if busy { busyLock.unlock(); return }
        busy = true
        busyLock.unlock()

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let order: RawByteOrder
        switch fmt {
        case kCVPixelFormatType_422YpCbCr8_yuvs: order = .yuyv
        case kCVPixelFormatType_422YpCbCr8: order = .uyvy
        default:
            release()
            report("Unerwartetes Bildformat \(fourCC(fmt)) von der Kamera.")
            return
        }
        guard let layout = FrameParser.layout(width: w, height: h) ?? self.layout,
              h >= layout.temperatureRow + layout.sensorHeight,
              let base = CVPixelBufferGetBaseAddress(pb) else {
            release()
            report("Unerwartete Bildgröße \(w)×\(h) von der Kamera.")
            return
        }
        let frame = FrameParser.parse(bytes: base, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                      layout: layout, order: order,
                                      timestamp: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
        DispatchQueue.main.async { [weak self] in
            self?.onFrame?(frame)
            self?.release()
        }
    }

    private func release() {
        busyLock.lock(); busy = false; busyLock.unlock()
    }

    private var lastReport = Date.distantPast
    private func report(_ msg: String) {
        guard Date().timeIntervalSince(lastReport) > 5 else { return }
        lastReport = Date()
        DispatchQueue.main.async { [weak self] in self?.onProblem?(msg) }
    }

    private func fourCC(_ v: OSType) -> String {
        let bytes = [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? "\(v)"
    }
}

/// An ordinary camera (e.g. the microscope camera) for the dual-light modes.
final class VisibleCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "visible.capture")
    private let lock = NSLock()
    private var image: CGImage?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    private(set) var runningID: String?

    var latestImage: CGImage? {
        lock.lock(); defer { lock.unlock() }
        return image
    }

    func start(deviceID: String) throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else { throw CaptureError.deviceNotFound }
        stop()
        session.beginConfiguration()
        for i in session.inputs { session.removeInput(i) }
        for o in session.outputs { session.removeOutput(o) }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch {
            session.commitConfiguration()
            throw CaptureError.cannotAddInput(error.localizedDescription)
        }
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        runningID = deviceID
        queue.async { [session] in session.startRunning() }
    }

    func stop() {
        runningID = nil
        lock.lock(); image = nil; lock.unlock()
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        lock.lock(); image = cg; lock.unlock()
    }
}
