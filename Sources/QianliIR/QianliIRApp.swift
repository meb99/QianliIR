import AppKit
import SwiftUI
import ThermalCore

@main
struct QianliIRApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var updater = Updater()

    var body: some Scene {
        WindowGroup("QianLi IR", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(updater)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            AppCommands(model: model)
            CommandGroup(after: .appInfo) {
                Button("Nach Updates suchen …") { Task { await updater.check(userInitiated: true) } }
            }
        }

        Window("3D-Ansicht", id: "3d") {
            Thermal3DWindow().environmentObject(model)
        }
        .defaultSize(width: 760, height: 560)

        Window("Platinenvergleich", id: "compare") {
            CompareWindow().environmentObject(model)
        }
        .defaultSize(width: 1100, height: 420)

        Window("Kamera-Diagnose", id: "diagnose") {
            DiagnosticsWindow().environmentObject(model)
        }
        .defaultSize(width: 720, height: 560)

        Window("Temperaturverlauf", id: "history") {
            HistoryWindow().environmentObject(model)
        }
        .defaultSize(width: 760, height: 380)

        Settings {
            SettingsView().environmentObject(model).environmentObject(updater)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started from a plain executable bundle: make sure we get a Dock icon and focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: Updater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                ThermalImageView()
                StatusBar()
            }
            .frame(minWidth: 520, minHeight: 420)
            SidebarView()
                .frame(minWidth: 270, idealWidth: 300, maxWidth: 380)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Picker("Werkzeug", selection: $model.tool) {
                    Image(systemName: "cursorarrow").help("Zeiger").tag(MeasureTool.none)
                    Image(systemName: "scope").help("Messpunkt setzen").tag(MeasureTool.spot)
                    Image(systemName: "rectangle.dashed").help("Messrahmen ziehen").tag(MeasureTool.rect)
                    Image(systemName: "line.diagonal").help("Messlinie ziehen (Temperaturprofil)").tag(MeasureTool.line)
                }
                .pickerStyle(.segmented)
            }
            ToolbarItemGroup {
                if let m = updater.available {
                    Button { updater.showSheet = true } label: {
                        Label("Update \(m.version)", systemImage: "arrow.down.circle.fill")
                    }
                    .help("Neue Version verfügbar")
                    .tint(.green)
                }
                Button { model.snapshot() } label: { Label("Foto", systemImage: "camera") }
                    .help("Foto speichern (PNG + Temperaturen als CSV)")
                    .disabled(model.image == nil)
                Button { model.toggleRecording() } label: {
                    Label(model.isRecording ? "Stopp" : "Video",
                          systemImage: model.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .help(model.isRecording ? "Aufnahme beenden" : "Video aufnehmen")
                .disabled(model.image == nil && !model.isRecording)
                Button { model.openFolder() } label: { Label("Ordner", systemImage: "folder") }
                    .help("Ordner mit Fotos und Videos öffnen")
                Toggle(isOn: $model.settings.quickSearch) {
                    Label("Schnellsuche", systemImage: "bolt.fill")
                }
                .help("Kurzschluss-Schnellsuche: nur die heißeste Stelle farbig")
                Button { openWindow(id: "3d") } label: { Label("3D", systemImage: "cube") }
                    .help("3D-Ansicht")
                Button { openWindow(id: "compare") } label: { Label("Vergleich", systemImage: "square.split.2x1") }
                    .help("Platinenvergleich (gut / defekt)")
                Button { openWindow(id: "history") } label: { Label("Verlauf", systemImage: "chart.xyaxis.line") }
                    .help("Temperaturverlauf")
            }
        }
        .navigationTitle("QianLi IR")
        .task {
            updater.startAutomaticChecks()
            await model.startup()
        }
        .sheet(isPresented: $updater.showSheet) { UpdateSheet().environmentObject(updater) }
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Bild") {
            Picker("Farbpalette", selection: $model.settings.palette) {
                ForEach(Palette.allCases) { Text($0.name).tag($0) }
            }
            Picker("Verbesserung", selection: $model.settings.enhancement) {
                ForEach(Enhancement.allCases) { Text($0.name).tag($0) }
            }
            Toggle("Superauflösung", isOn: $model.settings.superResolution)
            Divider()
            Button("Foto speichern") { model.snapshot() }
                .keyboardShortcut("s", modifiers: .command)
            Button(model.isRecording ? "Videoaufnahme beenden" : "Video aufnehmen") { model.toggleRecording() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Bilderordner öffnen") { model.openFolder() }
            Divider()
            Picker("Zwei-Kamera-Modus", selection: $model.settings.fusionMode) {
                ForEach(FusionMode.allCases) { Text($0.name).tag($0) }
            }
            Toggle("Kurzschluss-Schnellsuche", isOn: $model.settings.quickSearch)
                .keyboardShortcut("k", modifiers: .command)
        }
        CommandMenu("Messen") {
            Button("Kalibrierung zurücksetzen") { model.resetCalibration() }
            Divider()
            Button("Zeiger") { model.tool = .none }.keyboardShortcut("1", modifiers: .command)
            Button("Messpunkt") { model.tool = .spot }.keyboardShortcut("2", modifiers: .command)
            Button("Messrahmen") { model.tool = .rect }.keyboardShortcut("3", modifiers: .command)
            Button("Messlinie") { model.tool = .line }.keyboardShortcut("4", modifiers: .command)
            Button("Alle Messungen löschen") { model.clearMeasurements() }
            Divider()
            Toggle("Heißesten Punkt verfolgen", isOn: $model.settings.trackMax)
            Toggle("Kältesten Punkt verfolgen", isOn: $model.settings.trackMin)
            Toggle("Hochtemperatur-Alarm", isOn: $model.settings.alarmEnabled)
        }
        CommandMenu("Kamera") {
            Picker("Temperaturbereich", selection: $model.settings.highGain) {
                Text("Normal (bis ca. 150 °C)").tag(true)
                Text("Hoch (bis ca. 550 °C)").tag(false)
            }
            Button("Shutter / Kalibrieren") { model.runShutter() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!model.canControlCamera)
            Divider()
            Button("Kameras neu suchen") {
                model.refreshCameras()
                model.autoStart()
            }
            Button("Demo-Modus") { model.startDemo() }
        }
        CommandGroup(after: .toolbar) {
            Button("Drehen") { model.settings.rotation = model.settings.rotation.next }
                .keyboardShortcut("t", modifiers: .command)
            Toggle("Links/rechts spiegeln", isOn: $model.settings.flipH)
            Toggle("Oben/unten spiegeln", isOn: $model.settings.flipV)
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("Kamera-Diagnose …") { openWindow(id: "diagnose") }
        }
        CommandGroup(before: .windowList) {
            Button("3D-Ansicht") { openWindow(id: "3d") }
            Button("Platinenvergleich") { openWindow(id: "compare") }
            Button("Temperaturverlauf") { openWindow(id: "history") }
            Divider()
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: Updater

    var body: some View {
        Form {
            Section("Speicherort") {
                HStack {
                    Text(model.settings.saveFolder)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 300, alignment: .leading)
                    Button("Ändern …") { model.chooseFolder() }
                    Button("Standard") { model.settings.saveFolder = AppSettings.defaultSaveFolder }
                }
                Text("Fotos, Videos und Verlauf werden in Unterordnern gespeichert.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Temperatur") {
                Picker("Einheit", selection: $model.settings.unit) {
                    Text("Grad Celsius (°C)").tag(TemperatureUnit.celsius)
                    Text("Grad Fahrenheit (°F)").tag(TemperatureUnit.fahrenheit)
                }
                Toggle("Warnton bei Alarm", isOn: $model.settings.alarmSound)
            }
            Section("Updates") {
                Toggle("Automatisch nach Updates suchen", isOn: $updater.autoCheck)
                HStack {
                    Text("Installiert: Version \(updater.localVersion) (Build \(updater.localBuild))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Jetzt suchen") { Task { await updater.check(userInitiated: true) } }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
    }
}

struct UpdateSheet: View {
    @EnvironmentObject var updater: Updater
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.bold())
                    Text("Installiert: Version \(updater.localVersion) (Build \(updater.localBuild))")
                        .foregroundStyle(.secondary)
                }
            }
            content
            HStack {
                Button("Download-Seite") { NSWorkspace.shared.open(Updater.releasePage) }
                Spacer()
                switch updater.state {
                case .available:
                    Button("Später") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Jetzt aktualisieren") { updater.install() }
                        .keyboardShortcut(.defaultAction)
                case .downloading, .installing, .checking:
                    EmptyView()
                default:
                    Button("OK") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var title: String {
        switch updater.state {
        case .available(let m): return "Version \(m.version) ist da"
        case .upToDate: return "QianLi IR ist aktuell"
        case .checking: return "Suche nach Updates …"
        case .downloading, .installing: return "Update wird installiert"
        case .failed: return "Update nicht möglich"
        case .idle: return "Updates"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch updater.state {
        case .available(let m):
            Text("Was ist neu:").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(m.noteLines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline) {
                            Text("•")
                            Text(line).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            Text("Die App wird ersetzt und startet danach neu. Einstellungen, Fotos und Videos bleiben erhalten.")
                .font(.caption).foregroundStyle(.secondary)
        case .checking:
            ProgressView().frame(maxWidth: .infinity)
        case .downloading(let f):
            ProgressView("Lade herunter …", value: f, total: 1)
        case .installing:
            ProgressView("Installiere und starte neu …")
        case .failed(let msg):
            Text(msg).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        case .upToDate:
            Text("Du hast die neueste Version.")
        case .idle:
            EmptyView()
        }
    }
}
