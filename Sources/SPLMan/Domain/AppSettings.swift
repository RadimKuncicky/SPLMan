import Foundation

struct InputSelection: Codable, Equatable {
    var deviceUID: String
    var channel: Int
}

struct CalibrationKey: Hashable, Codable {
    let deviceUID: String
    let channel: Int
}

struct CalibrationRecord: Codable, Equatable {
    let offsetDB: Double
    let calibratedAt: Date
}

struct PersistedSettings: Codable, Equatable {
    var input: InputSelection?
    var displayedMetrics: [Metric] = [.laeq1, .aSlow, .laeq10]
    var calibrations: [CalibrationKey: CalibrationRecord] = [:]
    var thresholds = VisualThresholds()
}

final class SettingsStore {
    private let defaults: UserDefaults
    private let key = "SPLMan.settings.v1"
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PersistedSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? decoder.decode(PersistedSettings.self, from: data) else {
            return PersistedSettings()
        }
        return settings
    }

    func save(_ settings: PersistedSettings) {
        guard let data = try? encoder.encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
