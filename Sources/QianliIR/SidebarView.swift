import Charts
import SwiftUI
import ThermalCore

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                cameraSection
                cameraControlSection
                readingsSection
                imageSection
                rangeSection
                markerSection
                searchSection
                alarmSection
                viewSection
                dualSection
                calibrationSection
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var unit: TemperatureUnit { model.settings.unit }

    /// A temperature setting shown and edited in the selected unit.
    private func tempBinding(_ kp: WritableKeyPath<AppSettings, Float>) -> Binding<Double> {
        Binding(
            get: { Double(model.settings.unit.convert(model.settings[keyPath: kp])) },
            set: { model.settings[keyPath: kp] = model.settings.unit.toCelsius(Float($0)) }
        )
    }

    // MARK: Sections

    private var cameraSection: some View {
        GroupBox("Kamera") {
            VStack(alignment: .leading, spacing: 8) {
                let thermalCams = model.cameras.filter { $0.thermalSize != nil }
                Picker("Wärmebild", selection: Binding(
                    get: { model.isDemo ? "demo" : model.settings.thermalCameraID },
                    set: { id in
                        if id == "demo" { model.startDemo() } else { model.startCamera(id) }
                    })) {
                    ForEach(thermalCams) { cam in
                        Text("\(cam.name) (\(cam.thermalSize ?? ""))").tag(cam.id)
                    }
                    if thermalCams.isEmpty && !model.isDemo {
                        Text("– keine gefunden –").tag(model.settings.thermalCameraID)
                    }
                    Text("Demo (simulierte Platine)").tag("demo")
                }
                Button {
                    model.refreshCameras()
                    if !model.isRunning || model.isDemo { model.autoStart() }
                } label: {
                    Label("Kameras neu suchen", systemImage: "arrow.clockwise")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cameraControlSection: some View {
        GroupBox("Kamera-Einstellungen") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Bereich", selection: $model.settings.highGain) {
                    Text("Normal").tag(true)
                    Text("Hochtemperatur").tag(false)
                }
                .pickerStyle(.segmented)
                Text(model.settings.highGain ? "ca. −20 … 150 °C, feinere Auflösung" : "bis ca. 550 °C, z. B. für Heißluft und Lötkolben")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button {
                        model.runShutter()
                    } label: {
                        Label("Shutter / Kalibrieren", systemImage: "camera.aperture")
                    }
                    .disabled(!model.canControlCamera || model.cameraBusy)
                    if model.cameraBusy { ProgressView().controlSize(.small) }
                }
                Divider()
                HStack {
                    Text("Emissionsgrad")
                    Slider(value: Binding(get: { Double(model.settings.emissivity) },
                                          set: { model.settings.emissivity = Float(($0 * 100).rounded() / 100) }),
                           in: 0.1...1)
                    Text(String(format: "%.2f", model.settings.emissivity))
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                Menu("Material wählen") {
                    ForEach(Self.materials.indices, id: \.self) { i in
                        let m = Self.materials[i]
                        Button("\(m.0)  (\(String(format: "%.2f", m.1)))") { model.settings.emissivity = m.1 }
                    }
                }
                if model.settings.emissivity < 0.999 {
                    HStack {
                        Text("Umgebung")
                        TextField("", value: tempBinding(\.reflectedTemp), format: .number.precision(.fractionLength(0...1)))
                            .frame(width: 60)
                        Text(unit.symbol)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static let materials: [(String, Float)] = [
        ("Keine Korrektur", 1.00),
        ("Platine / Lötstopplack", 0.92),
        ("Kunststoff / Gehäuse", 0.95),
        ("IC-Gehäuse (Epoxid)", 0.93),
        ("Keramik-Kondensator", 0.90),
        ("Kaptonband / Isolierband", 0.95),
        ("Oxidiertes Kupfer", 0.65),
        ("Blankes Metall / Abschirmung", 0.20),
    ]

    private var readingsSection: some View {
        GroupBox("Messwerte") {
            VStack(alignment: .leading, spacing: 6) {
                if let s = model.stats, let f = model.frame {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                        GridRow {
                            Text("Max").foregroundStyle(.red)
                            Text(unit.format(s.max)).font(.title3.monospacedDigit().bold())
                        }
                        GridRow {
                            Text("Min").foregroundStyle(.blue)
                            Text(unit.format(s.min)).font(.title3.monospacedDigit())
                        }
                        GridRow {
                            Text("Ø")
                            Text(unit.format(s.mean)).monospacedDigit()
                        }
                        if let c = f.temperature(at: f.center) {
                            GridRow {
                                Text("Mitte")
                                Text(unit.format(c)).monospacedDigit()
                            }
                        }
                    }
                    ForEach(Array(model.spots.enumerated()), id: \.offset) { i, p in
                        HStack {
                            Text("P\(i + 1)").foregroundStyle(.green)
                            Text(f.temperature(at: p).map { unit.format($0) } ?? "–").monospacedDigit()
                            Spacer()
                            Button { model.spots.remove(at: i) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless)
                        }
                    }
                    ForEach(Array(model.rects.enumerated()), id: \.offset) { i, r in
                        let rs = f.stats(in: r)
                        HStack {
                            Text("R\(i + 1)").foregroundStyle(.yellow)
                            Text("▲\(unit.format(rs.max)) ▼\(unit.format(rs.min))")
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Spacer()
                            Button { model.rects.remove(at: i) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless)
                        }
                    }
                } else {
                    Text("Kein Bild").foregroundStyle(.secondary)
                }
                if let p = model.profile, p.temperatures.count > 1 {
                    HStack {
                        Text("Linie").foregroundStyle(.teal)
                        if let mi = p.maxIndex {
                            Text("▲\(unit.format(p.temperatures[mi])) ▼\(unit.format(p.temperatures.min() ?? 0))")
                                .monospacedDigit()
                        }
                        Spacer()
                        Button { model.line = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                    }
                    Chart {
                        ForEach(Array(p.temperatures.enumerated()), id: \.offset) { i, t in
                            LineMark(x: .value("Punkt", i), y: .value("Temperatur", unit.convert(t)))
                                .foregroundStyle(.teal)
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXAxis(.hidden)
                    .frame(height: 90)
                }
                Picker("Werkzeug", selection: $model.tool) {
                    ForEach(MeasureTool.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(toolHint).font(.caption).foregroundStyle(.secondary)
                if !model.spots.isEmpty || !model.rects.isEmpty {
                    Button("Alle Messungen löschen") { model.clearMeasurements() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var toolHint: String {
        switch model.tool {
        case .none: return "Maus über das Bild bewegen zeigt die Temperatur."
        case .spot: return "Ins Bild klicken setzt einen Messpunkt."
        case .rect: return "Im Bild ziehen setzt einen Messrahmen."
        case .line: return "Im Bild ziehen setzt eine Messlinie mit Temperaturprofil."
        }
    }

    private var imageSection: some View {
        GroupBox("Bild") {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], spacing: 6) {
                    ForEach(Palette.allCases) { p in
                        PaletteButton(palette: p, selected: model.settings.palette == p) {
                            model.settings.palette = p
                        }
                    }
                }
                Picker("Verbesserung", selection: $model.settings.enhancement) {
                    ForEach(Enhancement.allCases) { Text($0.name).tag($0) }
                }
                Toggle("Superauflösung (glatt hochrechnen)", isOn: $model.settings.superResolution)
                Picker("Einheit", selection: $model.settings.unit) {
                    Text("°C").tag(TemperatureUnit.celsius)
                    Text("°F").tag(TemperatureUnit.fahrenheit)
                }
                .pickerStyle(.segmented)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rangeSection: some View {
        GroupBox("Farbbereich") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Automatisch", isOn: $model.settings.autoRange)
                if !model.settings.autoRange {
                    HStack {
                        Text("von")
                        TextField("", value: tempBinding(\.fixedMin), format: .number.precision(.fractionLength(0...1)))
                            .frame(width: 60)
                        Text("bis")
                        TextField("", value: tempBinding(\.fixedMax), format: .number.precision(.fractionLength(0...1)))
                            .frame(width: 60)
                        Text(unit.symbol)
                    }
                    if let s = model.stats {
                        Button("Aktuellen Bereich übernehmen") {
                            model.settings.fixedMin = s.min.rounded(.down)
                            model.settings.fixedMax = s.max.rounded(.up)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var markerSection: some View {
        GroupBox("Markierungen") {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Heißester Punkt verfolgen", isOn: $model.settings.trackMax)
                Toggle("Kältester Punkt verfolgen", isOn: $model.settings.trackMin)
                Toggle("Mittelpunkt", isOn: $model.settings.showCenter)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var searchSection: some View {
        GroupBox("Kurzschluss-Schnellsuche") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Nur heiße Stelle farbig zeigen", isOn: $model.settings.quickSearch)
                if model.settings.quickSearch {
                    HStack {
                        Text("Bereich")
                        Slider(value: Binding(get: { Double(model.settings.quickSearchSpan) },
                                              set: { model.settings.quickSearchSpan = Float($0) }),
                               in: 0.5...15)
                        Text(String(format: "%.1f", unit.convertDelta(model.settings.quickSearchSpan)) + unit.symbol)
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                    Text("Alles, was mehr als diesen Wert unter dem heißesten Punkt liegt, wird grau.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var alarmSection: some View {
        GroupBox("Hochtemperatur-Alarm") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Alarm ein", isOn: $model.settings.alarmEnabled)
                HStack {
                    Text("Ab")
                    TextField("", value: tempBinding(\.alarmThreshold), format: .number.precision(.fractionLength(0...1)))
                        .frame(width: 60)
                    Text(unit.symbol)
                    Stepper("", value: tempBinding(\.alarmThreshold), step: 1).labelsHidden()
                }
                Toggle("Warnton", isOn: $model.settings.alarmSound)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var viewSection: some View {
        GroupBox("Ansicht") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button {
                        model.settings.rotation = model.settings.rotation.next
                    } label: {
                        Label("Drehen", systemImage: "rotate.right")
                    }
                    Text("\(model.settings.rotation.rawValue)°").foregroundStyle(.secondary)
                }
                Toggle("Links/rechts spiegeln", isOn: $model.settings.flipH)
                Toggle("Oben/unten spiegeln", isOn: $model.settings.flipV)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var dualSection: some View {
        GroupBox("Zwei-Kamera-Modus (Dual Light)") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Modus", selection: $model.settings.fusionMode) {
                    ForEach(FusionMode.allCases) { Text($0.name).tag($0) }
                }
                if model.settings.fusionMode != .thermal {
                    Picker("Kamera", selection: $model.settings.visibleCameraID) {
                        Text("– auswählen –").tag("")
                        ForEach(model.cameras.filter { $0.thermalSize == nil }) { cam in
                            Text(cam.name).tag(cam.id)
                        }
                    }
                    if model.settings.fusionMode != .visible {
                        HStack {
                            Text(model.settings.fusionMode == .blend ? "Anteil sichtbar" : "Konturen")
                            Slider(value: $model.settings.fusionWeight, in: 0...1)
                        }
                    }
                    Text("Ausrichtung").font(.caption).foregroundStyle(.secondary)
                    HStack { Text("←→").frame(width: 28); Slider(value: $model.settings.alignOffsetX, in: -0.5...0.5) }
                    HStack { Text("↑↓").frame(width: 28); Slider(value: $model.settings.alignOffsetY, in: -0.5...0.5) }
                    HStack { Text("Größe").frame(width: 42); Slider(value: $model.settings.alignScale, in: 0.5...2.5) }
                    Button("Ausrichtung zurücksetzen") {
                        model.settings.alignOffsetX = 0
                        model.settings.alignOffsetY = 0
                        model.settings.alignScale = 1
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var calibrationSection: some View {
        GroupBox("Kalibrierung") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Korrektur")
                    Stepper(value: Binding(get: { Double(model.settings.temperatureOffset) },
                                           set: { model.settings.temperatureOffset = Float(($0 * 10).rounded() / 10) }),
                            in: -20...20, step: 0.1) {
                        Text(String(format: "%+.1f", unit.convertDelta(model.settings.temperatureOffset)) + unit.symbol)
                            .monospacedDigit()
                    }
                }
                Text("Wird zu allen gemessenen Temperaturen addiert.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Kalibrierung zurücksetzen") { model.resetCalibration() }
                    .disabled(model.settings.temperatureOffset == 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PaletteButton: View {
    let palette: Palette
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                LinearGradient(colors: stride(from: 0, to: 256, by: 32).map { i -> Color in
                    let c = palette.lut[min(255, i)]
                    return Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
                } + [lastColor], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(palette.name).font(.caption2).lineLimit(1)
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private var lastColor: Color {
        let c = palette.lut[255]
        return Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }
}
