import Foundation
import ThermalCore

enum FusionMode: String, CaseIterable, Codable, Identifiable {
    /// Single thermal image
    case thermal
    /// Weighted average of thermal and visible image
    case blend
    /// Thermal colours with the visible picture's details on top
    case detail
    /// Single visible light image
    case visible

    var id: String { rawValue }
    var name: String {
        switch self {
        case .thermal: return "Nur Wärmebild"
        case .blend: return "Gewichtete Mischung"
        case .detail: return "Wärmebild + Konturen"
        case .visible: return "Nur sichtbares Licht"
        }
    }
}

/// Everything the user can set; saved between launches.
struct AppSettings: Codable, Equatable {
    var palette: Palette = .iron
    var enhancement: Enhancement = .universal
    var superResolution = true
    var unit: TemperatureUnit = .celsius

    var autoRange = true
    var fixedMin: Float = 20
    var fixedMax: Float = 80

    var rotation: Rotation = .r0
    var flipH = false
    var flipV = false

    var trackMax = true
    var trackMin = false
    var showCenter = true

    var alarmEnabled = false
    var alarmThreshold: Float = 60
    var alarmSound = true

    /// Correction added to every measured temperature (°C).
    var temperatureOffset: Float = 0
    /// Emissivity of the measured surface (1 = no correction) and reflected temperature (°C).
    var emissivity: Float = 1
    var reflectedTemp: Float = 25

    /// Camera gain: true = normal range (about −20…150 °C), false = high temperature range (up to about 550 °C).
    var highGain = true

    /// Quick search: only the area within this many degrees of the hottest point is coloured.
    var quickSearch = false
    var quickSearchSpan: Float = 3

    var fusionMode: FusionMode = .thermal
    var fusionWeight: Double = 0.5
    var visibleCameraID: String = ""
    var alignOffsetX: Double = 0
    var alignOffsetY: Double = 0
    var alignScale: Double = 1

    var thermalCameraID: String = ""
    var saveFolder: String = AppSettings.defaultSaveFolder

    static var defaultSaveFolder: String {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
        return pictures.appendingPathComponent("QianLi IR").path
    }

    private static let key = "QianliIR.settings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: AppSettings.key)
        }
    }
}
