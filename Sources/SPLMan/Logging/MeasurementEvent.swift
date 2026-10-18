import Foundation

enum MeasurementEventType: String, Codable, Sendable {
    case recordingStarted = "RecordingStarted"
    case recordingStopped = "RecordingStopped"
    case recordingPaused = "RecordingPaused"
    case recordingResumed = "RecordingResumed"
    case calibrationChanged = "CalibrationChanged"
    case audioDeviceChanged = "AudioDeviceChanged"
    case sampleRateChanged = "SampleRateChanged"
    case inputGainChanged = "InputGainChanged"
    case audioDropout = "AudioDropout"
    case bufferOverflow = "BufferOverflow"
    case clippingDetected = "ClippingDetected"
    case alarmTriggered = "AlarmTriggered"
    case alarmCleared = "AlarmCleared"
    case configurationChanged = "ConfigurationChanged"
    case storageError = "StorageError"
    case applicationInterrupted = "ApplicationInterrupted"
}

struct MeasurementEvent: Sendable {
    let id: UUID
    let sessionID: UUID
    let timestamp: Date
    let type: MeasurementEventType
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        timestamp: Date = Date(),
        type: MeasurementEventType,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.type = type
        self.metadata = metadata
    }
}
