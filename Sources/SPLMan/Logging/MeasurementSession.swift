import Foundation

enum MeasurementSessionStatus: String, Codable, Sendable {
    case created = "Created"
    case recording = "Recording"
    case paused = "Paused"
    case completed = "Completed"
    case interrupted = "Interrupted"
    case failed = "Failed"

    var isFinished: Bool {
        switch self {
        case .completed, .interrupted, .failed: true
        case .created, .recording, .paused: false
        }
    }
}

struct MeasurementSession: Sendable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date?
    let name: String
    let location: String
    let note: String?
    let microphoneID: String?
    let deviceUID: String
    let channel: Int
    let sampleRate: Double
    let calibrationOffset: Double
    let calibratedAt: Date
    let appVersion: String
    let measurementConfiguration: [String: String]
    let status: MeasurementSessionStatus

    init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        name: String = "",
        location: String = "",
        note: String? = nil,
        microphoneID: String? = nil,
        deviceUID: String,
        channel: Int,
        sampleRate: Double,
        calibrationOffset: Double,
        calibratedAt: Date,
        appVersion: String,
        measurementConfiguration: [String: String] = [:],
        status: MeasurementSessionStatus = .created
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.name = name
        self.location = location
        self.note = note
        self.microphoneID = microphoneID
        self.deviceUID = deviceUID
        self.channel = channel
        self.sampleRate = sampleRate
        self.calibrationOffset = calibrationOffset
        self.calibratedAt = calibratedAt
        self.appVersion = appVersion
        self.measurementConfiguration = measurementConfiguration
        self.status = status
    }

    func updating(status: MeasurementSessionStatus, at timestamp: Date) -> MeasurementSession {
        MeasurementSession(
            id: id,
            startedAt: startedAt,
            endedAt: status.isFinished ? timestamp : nil,
            name: name,
            location: location,
            note: note,
            microphoneID: microphoneID,
            deviceUID: deviceUID,
            channel: channel,
            sampleRate: sampleRate,
            calibrationOffset: calibrationOffset,
            calibratedAt: calibratedAt,
            appVersion: appVersion,
            measurementConfiguration: measurementConfiguration,
            status: status
        )
    }
}

struct MeasurementSessionInspection: Sendable {
    let sessionID: UUID
    let status: MeasurementSessionStatus
    let startedAt: Date?
    let lastTimestamp: Date?

    var isUnfinished: Bool { !status.isFinished }
}
