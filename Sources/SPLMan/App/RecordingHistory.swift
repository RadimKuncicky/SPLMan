import Foundation

struct RecordingMetadataDraft: Codable, Equatable {
    var eventName = ""
    var location = ""
    var note = ""
    var microphoneID = ""
}

struct AlarmSettings: Codable, Equatable {
    var isEnabled = true
    var laeq30MinuteLimit = 99.0
    var lcPeakLimit = 135.0
}

struct RecordingHistoryEntry: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        case recording
        case completed
        case interrupted
        case failed

        var title: String {
            switch self {
            case .recording: L10n.text("Probíhá")
            case .completed: L10n.text("Dokončeno")
            case .interrupted: L10n.text("Přerušeno")
            case .failed: L10n.text("Chyba")
            }
        }
    }

    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    let eventName: String
    let location: String
    let filePath: String
    var state: State
}

final class RecordingHistoryStore {
    private let defaults: UserDefaults
    private let historyKey = "SPLMan.recordingHistory.v1"
    private let metadataKey = "SPLMan.recordingMetadata.v1"
    private let alarmKey = "SPLMan.alarmSettings.v1"
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadMetadata() -> RecordingMetadataDraft {
        guard let data = defaults.data(forKey: metadataKey),
              let metadata = try? decoder.decode(RecordingMetadataDraft.self, from: data) else {
            return RecordingMetadataDraft()
        }
        return metadata
    }

    func saveMetadata(_ metadata: RecordingMetadataDraft) {
        guard let data = try? encoder.encode(metadata) else { return }
        defaults.set(data, forKey: metadataKey)
    }

    func loadAlarmSettings() -> AlarmSettings {
        guard let data = defaults.data(forKey: alarmKey),
              let settings = try? decoder.decode(AlarmSettings.self, from: data) else {
            return AlarmSettings()
        }
        return settings
    }

    func saveAlarmSettings(_ settings: AlarmSettings) {
        guard let data = try? encoder.encode(settings) else { return }
        defaults.set(data, forKey: alarmKey)
    }

    func loadHistory() -> [RecordingHistoryEntry] {
        guard let data = defaults.data(forKey: historyKey),
              var history = try? decoder.decode([RecordingHistoryEntry].self, from: data) else {
            return []
        }
        var changed = false
        for index in history.indices where history[index].state == .recording {
            history[index].state = .interrupted
            history[index].endedAt = history[index].endedAt ?? Date()
            changed = true
        }
        if changed { saveHistory(history) }
        return history
    }

    func saveHistory(_ history: [RecordingHistoryEntry]) {
        guard let data = try? encoder.encode(Array(history.prefix(100))) else { return }
        defaults.set(data, forKey: historyKey)
    }
}
