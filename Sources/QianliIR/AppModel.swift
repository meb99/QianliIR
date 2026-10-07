import AppKit
import AVFoundation
import Combine
import Foundation
import ThermalCore

enum MeasureTool: String, CaseIterable, Identifiable {
    case none, spot, rect, line
    var id: String { rawValue }
    var name: String {
        switch self {
        case .none: return "Zeiger"
        case .spot: return "Messpunkt"
        case .rect: return "Messrahmen"
        case .line: return "Linie"
        }
    }
}

struct HistorySample: Identifiable {
    let id = UUID()
    let time: Date
    let max: Float
    let min: Float
    let center: Float
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = AppSettings.load() {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            settingsChanged(from: oldValue)
        }
    }

    // Live picture
    @Published private(set) var image: CGImage?
    @Published private(set) var frame: ThermalFrame?
    @Published private(set) var stats: TemperatureStats?
    @Published private(set) var rendered: RGBAImage?
    @Published private(set) var alarmActive = false

    // Sources
    @Published private(set) var cameras: [CameraInfo] = []
    @Published private(set) var sourceName = "Keine Kamera"
    @Published private(set) var isDemo = false
    @Published private(set) var isRunning = false
    @Published var message: String?

    // Measurements
    @Published var tool: MeasureTool = .none
    @Published var spots: [PixelPoint] = [] { didSet { rerender() } }
    @Published var rects: [PixelRect] = [] { didSet { rerender() } }
    @Published var pendingRect: PixelRect? { didSet { rerender() } }
    /// Measuring line (start, end) and its temperature profile.
    @Published var line: [PixelPoint]? { didSet { rerender() } }
    @Published private(set) var profile: LineProfile?
    @Published private(set) var cameraBusy = false
    @Published var hover: PixelPoint?

    // Recording, comparison, history
    @Published private(set) var isRecording = false
    @Published private(set) var recordingSeconds = 0
    @Published var reference: ThermalFrame?
    @Published private(set) var history: [HistorySample] = []
    @Published var historyPaused = false

    private let thermal = ThermalCapture()
    private let visible = VisibleCapture()
    private let compositor = Compositor()
    private let control = CameraControl()
    private var recorder: VideoRecorder?
    private var recordTimer: Timer?
    private var demoTimer: Timer?
    private var demoStart = Date()
    private var lastRaw: ThermalFrame?
    private var lastHistory = Date.distantPast
    private var lastAlarmSound = Date.distantPast
    private var started = false

    init() {
        thermal.onFrame = { [weak self] f in self?.process(f, live: true) }
        thermal.onProblem = { [weak self] msg in self?.message = msg }
    }

    // MARK: - Sources

    func startup() async {
        guard !started else { return }
        started = true
        let ok = await CameraDirectory.requestAccess()
        if !ok {
            message = "Kein Kamerazugriff. Bitte unter Systemeinstellungen › Datenschutz & Sicherheit › Kamera „QianLi IR“ erlauben."
        }
        refreshCameras()
        NotificationCenter.default.addObserver(forName: .AVCaptureDeviceWasConnected, object: nil, queue: .main) { [weak self] _ in
            let model = self
            Task { @MainActor in model?.deviceListChanged(connected: true) }
        }
        NotificationCenter.default.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: .main) { [weak self] _ in
            let model = self
            Task { @MainActor in model?.deviceListChanged(connected: false) }
        }
        autoStart()
    }

    func refreshCameras() {
        cameras = CameraDirectory.cameras()
    }

    private func deviceListChanged(connected: Bool) {
        refreshCameras()
        if connected, isDemo || !isRunning {
            autoStart()
        } else if !connected, !isDemo, !cameras.contains(where: { $0.id == settings.thermalCameraID }) {
            isRunning = false
            sourceName = "Keine Kamera"
            message = "Wärmebildkamera wurde getrennt."
        }
        updateVisibleCamera()
    }

    /// Picks the thermal camera automatically (the last used one, otherwise the first one found).
    func autoStart() {
        let thermalCams = cameras.filter { $0.thermalSize != nil }
        if let cam = thermalCams.first(where: { $0.id == settings.thermalCameraID }) ?? thermalCams.first {
            startCamera(cam.id)
        } else if !isDemo {
            let others = cameras.map(\.name)
            message = others.isEmpty
                ? "Keine Kamera gefunden. Kamera per USB anschließen – oder den Demo-Modus zum Ausprobieren starten."
                : "Keine Wärmebildkamera erkannt. Gefunden: \(others.joined(separator: ", ")). Bitte „Kamera-Diagnose“ öffnen und den Text schicken."
        }
    }

    func startCamera(_ id: String) {
        stopDemo()
        thermal.stop()
        do {
            try thermal.start(deviceID: id)
            settings.thermalCameraID = id
            if let device = AVCaptureDevice(uniqueID: id) { control.attach(to: device) }
            if !settings.highGain { applyGain() }
            sourceName = thermal.deviceName
            isRunning = true
            message = nil
            clearMeasurements()
        } catch {
            isRunning = false
            message = error.localizedDescription
        }
        updateVisibleCamera()
    }

    func startDemo() {
        thermal.stop()
        control.detach()
        demoTimer?.invalidate()
        demoStart = Date()
        let scene = DemoScene()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            let model = self
            Task { @MainActor in
                guard let model else { return }
                model.process(scene.frame(at: Date().timeIntervalSince(model.demoStart)), live: true)
            }
        }
        isDemo = true
        isRunning = true
        sourceName = "Demo (simulierte Platine)"
        message = nil
        clearMeasurements()
    }

    private func stopDemo() {
        demoTimer?.invalidate()
        demoTimer = nil
        isDemo = false
    }

    private func updateVisibleCamera() {
        let id = settings.visibleCameraID
        let wanted = settings.fusionMode != .thermal && !id.isEmpty && id != settings.thermalCameraID
        if !wanted {
            if visible.runningID != nil { visible.stop() }
            return
        }
        guard visible.runningID != id else { return }
        do { try visible.start(deviceID: id) } catch { message = error.localizedDescription }
    }

    // MARK: - Processing

    private func settingsChanged(from old: AppSettings) {
        if old.rotation != settings.rotation || old.flipH != settings.flipH || old.flipV != settings.flipV {
            clearMeasurements()
        }
        if old.fusionMode != settings.fusionMode || old.visibleCameraID != settings.visibleCameraID {
            updateVisibleCamera()
        }
        if !settings.alarmEnabled { alarmActive = false }
        if old.highGain != settings.highGain { applyGain() }
        rerender()
    }

    private func rerender() {
        if let raw = lastRaw { process(raw, live: false) }
    }

    private func process(_ raw: ThermalFrame, live: Bool) {
        lastRaw = raw
        let st = settings
        let f = EmissivityCorrection(emissivity: st.emissivity, reflectedTemp: st.reflectedTemp)
            .apply(to: raw)
            .offset(by: st.temperatureOffset)
            .transformed(rotation: st.rotation, flipH: st.flipH, flipV: st.flipV)
        let s = f.stats()

        var options = RenderOptions(palette: st.palette, enhancement: st.enhancement)
        if !st.autoRange && st.fixedMax > st.fixedMin { options.fixedRange = st.fixedMin...st.fixedMax }
        if st.quickSearch { options.isothermThreshold = s.max - st.quickSearchSpan }
        let r = ThermalRenderer.render(f, options: options)

        let alarm = st.alarmEnabled && s.max >= st.alarmThreshold
        if alarm && st.alarmSound && live && Date().timeIntervalSince(lastAlarmSound) > 1.5 {
            lastAlarmSound = Date()
            (NSSound(named: NSSound.Name("Sosumi")) ?? NSSound(named: NSSound.Name("Basso")))?.play()
        }

        let input = CompositeInput(frame: f, rendered: r, stats: s, settings: st,
                                   spots: spots, rects: rects, pendingRect: pendingRect, line: line,
                                   visible: st.fusionMode == .thermal ? nil : visible.latestImage,
                                   alarm: alarm)
        let img = compositor.compose(input)

        frame = f
        stats = s
        if let l = line, l.count == 2 { profile = LineProfile(frame: f, from: l[0], to: l[1]) } else { profile = nil }
        rendered = r
        alarmActive = alarm
        image = img

        guard live else { return }
        if let img, let recorder { recorder.append(img) }
        if !historyPaused && Date().timeIntervalSince(lastHistory) >= 0.2 {
            lastHistory = Date()
            history.append(HistorySample(time: lastHistory, max: s.max, min: s.min,
                                         center: f.temperature(at: f.center) ?? s.mean))
            if history.count > 3000 { history.removeFirst(history.count - 3000) }
        }
    }

    // MARK: - Measurements

    func temperature(at p: PixelPoint) -> Float? { frame?.temperature(at: p) }

    func clearMeasurements() {
        spots = []
        rects = []
        pendingRect = nil
        line = nil
    }

    func addSpot(_ p: PixelPoint) {
        guard frame?.contains(p) == true else { return }
        if spots.count >= 9 { spots.removeFirst() }
        spots.append(p)
    }

    func addRect(_ r: PixelRect) {
        guard let f = frame, let rr = r.clamped(width: f.width, height: f.height), rr.width > 1, rr.height > 1 else { return }
        if rects.count >= 6 { rects.removeFirst() }
        rects.append(rr)
    }

    func resetCalibration() {
        settings.temperatureOffset = 0
        settings.emissivity = 1
        settings.reflectedTemp = 25
    }

    // MARK: - Camera commands

    var canControlCamera: Bool { !isDemo && isRunning && control.isAvailable }

    /// Closes the shutter once so the camera recalibrates (FFC).
    func runShutter() {
        guard !isDemo else { return }
        cameraBusy = true
        control.shutter { [weak self] err in
            self?.cameraBusy = false
            self?.message = err ?? "Kamera kalibriert (Shutter)."
        }
    }

    private func applyGain() {
        guard !isDemo, isRunning else { return }
        cameraBusy = true
        let high = settings.highGain
        control.setHighGain(high) { [weak self] err in
            self?.cameraBusy = false
            self?.message = err ?? (high ? "Normaler Temperaturbereich aktiv." : "Hochtemperatur-Bereich aktiv.")
        }
    }

    // MARK: - Files

    var saveFolderURL: URL { URL(fileURLWithPath: settings.saveFolder, isDirectory: true) }

    private func ensureFolder(_ sub: String) -> URL? {
        let url = saveFolderURL.appendingPathComponent(sub, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            message = "Ordner kann nicht angelegt werden: \(error.localizedDescription)"
            return nil
        }
    }

    private func timestampName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "IR_" + f.string(from: Date())
    }

    /// Saves the picture as PNG and the temperatures as CSV.
    func snapshot() {
        guard let img = image, let f = frame, let dir = ensureFolder("Fotos") else { return }
        let name = timestampName()
        do {
            if let png = ImageUtil.pngData(img) {
                try png.write(to: dir.appendingPathComponent(name + ".png"))
            }
            try CSVExport.temperatures(f, unit: settings.unit)
                .write(to: dir.appendingPathComponent(name + "_Temperaturen.csv"), atomically: true, encoding: .utf8)
            message = "Foto gespeichert: \(name).png"
            NSSound(named: NSSound.Name("Tink"))?.play()
        } catch {
            message = "Speichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func toggleRecording() {
        if let rec = recorder {
            recorder = nil
            recordTimer?.invalidate()
            isRecording = false
            rec.finish { url in
                Task { @MainActor in self.message = "Video gespeichert: \(url.lastPathComponent)" }
            }
            return
        }
        guard let img = image, let dir = ensureFolder("Videos") else { return }
        do {
            let url = dir.appendingPathComponent(timestampName() + ".mov")
            recorder = try VideoRecorder(url: url, width: img.width, height: img.height)
            isRecording = true
            recordingSeconds = 0
            recordTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                let model = self
                Task { @MainActor in
                    guard let model, let r = model.recorder else { return }
                    model.recordingSeconds = Int(r.duration)
                }
            }
        } catch {
            message = "Aufnahme kann nicht starten: \(error.localizedDescription)"
        }
    }

    func openFolder() {
        guard let dir = ensureFolder("") else { return }
        NSWorkspace.shared.open(dir)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveFolderURL
        panel.prompt = "Auswählen"
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveFolder = url.path
        }
    }

    // MARK: - Comparison & history

    func captureReference() {
        reference = frame
    }

    func clearHistory() { history = [] }

    func exportHistory() {
        guard !history.isEmpty, let dir = ensureFolder("Verlauf") else { return }
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        let u = settings.unit
        func n(_ v: Float) -> String { String(format: "%.2f", u.convert(v)).replacingOccurrences(of: ".", with: ",") }
        var csv = "Zeit;Max \(u.symbol);Min \(u.symbol);Mitte \(u.symbol)\n"
        for h in history { csv += "\(df.string(from: h.time));\(n(h.max));\(n(h.min));\(n(h.center))\n" }
        let url = dir.appendingPathComponent(timestampName() + "_Verlauf.csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            message = "Verlauf gespeichert: \(url.lastPathComponent)"
        } catch {
            message = "Speichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }
}
