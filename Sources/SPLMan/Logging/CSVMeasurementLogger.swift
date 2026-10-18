import Foundation

final class RecordingErrorStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "SPLMan.pendingRecordingError"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> String? { defaults.string(forKey: key) }

    func save(_ message: String) {
        defaults.set(message, forKey: key)
        defaults.synchronize()
    }

    func clear() {
        defaults.removeObject(forKey: key)
        defaults.synchronize()
    }
}

struct CSVMeasurementRecord: Sendable {
    let timestamp: Date
    let laeq1: Double?
    let laeq10: Double?
    let laeq15: Double?
    let lceq1: Double?
    let lceq10: Double?
    let aSlow: Double?
    let cSlow: Double?
    let lcPeak: Double?
    let lafMax: Double?
    let cMinusA1: Double?
    let cMinusA10: Double?
    let cMinusASlow: Double?
    let deviceUID: String
    let channel: Int
    let calibrationOffset: Double
    let calibratedAt: Date
}

enum CSVMeasurementLoggerError: LocalizedError, Sendable {
    case alreadyStarted
    case notStarted
    case queueOverflow(capacity: Int)
    case sessionMismatch(expected: UUID, actual: UUID)
    case nonMonotonicSecondCount(previous: UInt64, current: UInt64)

    var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            L10n.text("Measurement logging is already active.")
        case .notStarted:
            L10n.text("Measurement logging is not active.")
        case let .queueOverflow(capacity):
            L10n.format(
                "Measurement logging queue exceeded its capacity of %d pending writes.",
                Int32(clamping: capacity)
            )
        case let .sessionMismatch(expected, actual):
            L10n.format("Record belongs to session %@, expected %@.", actual.uuidString, expected.uuidString)
        case let .nonMonotonicSecondCount(previous, current):
            L10n.format("Completed-second count moved from %llu to %llu.", previous, current)
        }
    }
}

final class CSVMeasurementLogger: @unchecked Sendable {
    fileprivate enum Column: Int, CaseIterable {
        case timestamp, laeq1Minute, laeq10Minutes, laeq15Minutes, lceq1Minute, lceq10Minutes
        case aSlow, cSlow, lcPeak, lafMax, cMinusA1Minute, cMinusA10Minutes, cMinusASlow
        case inputDeviceUID, inputChannel, calibrationOffset, calibratedAt
        case rowType, timestampUTC, sessionID, sessionStatus, measurementState, measurementStateReason
        case completedSecondCount, processedFrameCount
        case laeq1Second, lceq1Second, lzeq1Second, lafMax1Second, lasMax1Second, lcPeak1Second
        case laeq30Minutes, lceq30Minutes
        case gapStartedAtUTC, gapEndedAtUTC, lostSecondIntervals
        case eventID, eventType, eventMetadataJSON
        case sessionStartedAtUTC, sessionEndedAtUTC, sessionName, measurementLocation, sessionNote
        case microphoneID, sampleRateHz, appVersion, measurementConfigurationJSON
    }

    private enum RowType: String {
        case legacySample = "legacy_sample"
        case session, sample, event, gap, error
    }

    private enum Lifecycle { case idle, starting, acceptingWrites, closing, closed }

    private static let headerFields = [
        "timestamp", "laeq_1_min_db", "laeq_10_min_db", "laeq_15_min_db",
        "lceq_1_min_db", "lceq_10_min_db", "a_slow_db", "c_slow_db", "lc_peak_db",
        "laf_max_db", "c_minus_a_1_min_db", "c_minus_a_10_min_db", "c_minus_a_slow_db",
        "input_device_uid", "input_channel", "calibration_offset_db", "calibrated_at",
        "row_type", "timestamp_utc", "session_id", "session_status", "measurement_state",
        "measurement_state_reason",
        "completed_second_count", "processed_frame_count", "laeq_1s_db", "lceq_1s_db",
        "lzeq_1s_db", "lafmax_1s_db", "lasmax_1s_db", "lcpeak_1s_db", "laeq_30_min_db",
        "lceq_30_min_db", "gap_started_at_utc", "gap_ended_at_utc", "lost_second_intervals",
        "event_id", "event_type", "event_metadata_json", "session_started_at_utc",
        "session_ended_at_utc", "session_name", "measurement_location", "session_note",
        "microphone_id", "sample_rate_hz", "app_version", "measurement_configuration_json"
    ]
    private static let header = headerFields.joined(separator: ",") + "\n"

    private let queue = DispatchQueue(label: "cz.splman.csv-logger", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let stateLock = NSLock()
    private let maximumPendingWrites: Int
    private let synchronizationInterval: Int
    private var lifecycle = Lifecycle.idle
    private var pendingWriteCount = 0
    private var overflowedWriteCount = 0

    // Queue-confined state.
    private var fileHandle: FileHandle?
    private var activeSession: MeasurementSession?
    private var errorReported = false
    private var writesSinceSynchronization = 0
    private var lastCompletedSecondCount: UInt64?
    private var lastSampleTimestamp: Date?

    init(maximumPendingWrites: Int = 120, synchronizationInterval: Int = 1) {
        self.maximumPendingWrites = max(1, maximumPendingWrites)
        self.synchronizationInterval = max(1, synchronizationInterval)
        queue.setSpecific(key: queueKey, value: 1)
    }

    func start(at url: URL, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        start(at: url, session: nil, completion: completion)
    }

    func start(
        at url: URL,
        session: MeasurementSession,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        start(at: url, session: Optional(session), completion: completion)
    }

    private func start(
        at url: URL,
        session: MeasurementSession?,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        stateLock.lock()
        guard lifecycle == .idle || lifecycle == .closed else {
            stateLock.unlock()
            queue.async { completion(.failure(CSVMeasurementLoggerError.alreadyStarted)) }
            return
        }
        lifecycle = .starting
        stateLock.unlock()

        queue.async { [self] in
            do {
                let startedSession = session?.updating(status: .recording, at: session?.startedAt ?? Date())
                var content = Self.header
                if let startedSession {
                    content += Self.sessionLine(startedSession, timestamp: startedSession.startedAt)
                    content += Self.eventLine(MeasurementEvent(
                        sessionID: startedSession.id,
                        timestamp: startedSession.startedAt,
                        type: .recordingStarted
                    ), sessionStatus: .recording)
                }
                try Data(content.utf8).write(to: url, options: .atomic)
                fileHandle = try FileHandle(forWritingTo: url)
                try fileHandle?.seekToEnd()
                activeSession = startedSession
                errorReported = false
                writesSinceSynchronization = 0
                lastCompletedSecondCount = nil
                lastSampleTimestamp = nil
                stateLock.lock()
                if lifecycle == .starting { lifecycle = .acceptingWrites }
                stateLock.unlock()
                completion(.success(()))
            } catch {
                _ = closeFile()
                stateLock.lock()
                lifecycle = .closed
                stateLock.unlock()
                completion(.failure(error))
            }
        }
    }

    func append(_ record: CSVMeasurementRecord, onError: @escaping @Sendable (Error) -> Void) {
        enqueue(onError: onError) { [self] in
            try write(Self.legacyLine(record, session: activeSession))
        }
    }

    func append(_ sample: MeasurementSample, onError: @escaping @Sendable (Error) -> Void) {
        enqueue(onError: onError) { [self] in
            let session = try requireSession(sample.sessionID)
            if let previous = lastCompletedSecondCount {
                guard sample.completedSecondCount > previous else {
                    let error = CSVMeasurementLoggerError.nonMonotonicSecondCount(
                        previous: previous, current: sample.completedSecondCount
                    )
                    try write(Self.errorLine(
                        sessionID: session.id,
                        status: session.status,
                        timestamp: sample.timestamp,
                        type: .storageError,
                        message: error.localizedDescription
                    ))
                    throw error
                }
                if sample.completedSecondCount > previous + 1 {
                    let lost = sample.completedSecondCount - previous - 1
                    let gapStart = lastSampleTimestamp?.addingTimeInterval(1)
                        ?? sample.timestamp.addingTimeInterval(-Double(lost))
                    try write(Self.gapLine(MeasurementGap(
                        sessionID: session.id,
                        startedAt: gapStart,
                        endedAt: sample.timestamp,
                        lostSecondIntervals: lost,
                        reason: "Missing completed-second samples"
                    ), sessionStatus: session.status))
                }
            }
            try write(Self.sampleLine(sample, session: session))
            lastCompletedSecondCount = sample.completedSecondCount
            lastSampleTimestamp = sample.timestamp
        }
    }

    func append(_ event: MeasurementEvent, onError: @escaping @Sendable (Error) -> Void) {
        enqueue(onError: onError) { [self] in
            let session = try requireSession(event.sessionID)
            try write(Self.eventLine(event, sessionStatus: session.status))
        }
    }

    func appendGap(_ gap: MeasurementGap, onError: @escaping @Sendable (Error) -> Void) {
        enqueue(onError: onError) { [self] in
            let session = try requireSession(gap.sessionID)
            try write(Self.gapLine(gap, sessionStatus: session.status))
        }
    }

    func updateSession(
        status: MeasurementSessionStatus,
        at timestamp: Date = Date(),
        onError: @escaping @Sendable (Error) -> Void
    ) {
        enqueue(onError: onError) { [self] in
            guard let activeSession else { throw CSVMeasurementLoggerError.notStarted }
            let updated = activeSession.updating(status: status, at: timestamp)
            try write(Self.sessionLine(updated, timestamp: timestamp))
            self.activeSession = updated
        }
    }

    func flush(completion: @escaping @Sendable (Result<Void, Error>) -> Void = { _ in }) {
        queue.async { [self] in
            do {
                guard let fileHandle else { throw CSVMeasurementLoggerError.notStarted }
                try writePendingOverflowIfNeeded()
                try fileHandle.synchronize()
                writesSinceSynchronization = 0
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func stop(
        waitUntilClosed: Bool = false,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void = { _ in }
    ) {
        stop(finalStatus: .completed, waitUntilClosed: waitUntilClosed, completion: completion)
    }

    func stop(
        finalStatus: MeasurementSessionStatus,
        waitUntilClosed: Bool = false,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void = { _ in }
    ) {
        stateLock.lock()
        if lifecycle == .starting || lifecycle == .acceptingWrites { lifecycle = .closing }
        stateLock.unlock()

        let close = { [self] in
            var firstError: Error?
            do {
                try writePendingOverflowIfNeeded()
                if let activeSession {
                    let timestamp = Date()
                    let type: MeasurementEventType = finalStatus == .interrupted
                        ? .applicationInterrupted : .recordingStopped
                    try write(Self.eventLine(MeasurementEvent(
                        sessionID: activeSession.id,
                        timestamp: timestamp,
                        type: type,
                        metadata: ["final_status": finalStatus.rawValue]
                    ), sessionStatus: activeSession.status), synchronize: false)
                    let finished = activeSession.updating(status: finalStatus, at: timestamp)
                    try write(Self.sessionLine(finished, timestamp: timestamp), synchronize: false)
                    self.activeSession = finished
                }
            } catch {
                firstError = error
            }
            let closeResult = closeFile()
            activeSession = nil
            lastCompletedSecondCount = nil
            lastSampleTimestamp = nil
            if firstError == nil, case let .failure(error) = closeResult { firstError = error }
            stateLock.lock()
            lifecycle = .closed
            stateLock.unlock()
            firstError.map { completion(.failure($0)) } ?? completion(.success(()))
        }
        if waitUntilClosed, DispatchQueue.getSpecific(key: queueKey) == nil {
            queue.sync(execute: close)
        } else if waitUntilClosed {
            close()
        } else {
            queue.async(execute: close)
        }
    }

    static func inspectSession(at url: URL) throws -> MeasurementSessionInspection? {
        let rows = parseCSV(try String(contentsOf: url, encoding: .utf8))
        guard let header = rows.first else { return nil }
        let columns = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0) })
        guard let sessionIndex = columns[headerFields[Column.sessionID.rawValue]],
              let statusIndex = columns[headerFields[Column.sessionStatus.rawValue]] else { return nil }
        let startedIndex = columns[headerFields[Column.sessionStartedAtUTC.rawValue]]
        let timestampIndex = columns[headerFields[Column.timestampUTC.rawValue]]
        var sessionID: UUID?
        var status: MeasurementSessionStatus?
        var startedAt: Date?
        var lastTimestamp: Date?
        for row in rows.dropFirst() {
            if row.indices.contains(sessionIndex), let id = UUID(uuidString: row[sessionIndex]) {
                sessionID = id
            }
            if row.indices.contains(statusIndex), let value = MeasurementSessionStatus(rawValue: row[statusIndex]) {
                status = value
            }
            if let startedIndex, row.indices.contains(startedIndex), !row[startedIndex].isEmpty {
                startedAt = parseTimestamp(row[startedIndex]) ?? startedAt
            }
            if let timestampIndex, row.indices.contains(timestampIndex), !row[timestampIndex].isEmpty {
                lastTimestamp = parseTimestamp(row[timestampIndex]) ?? lastTimestamp
            }
        }
        guard let sessionID, let status else { return nil }
        return MeasurementSessionInspection(
            sessionID: sessionID, status: status, startedAt: startedAt, lastTimestamp: lastTimestamp
        )
    }

    private func enqueue(
        onError: @escaping @Sendable (Error) -> Void,
        operation: @escaping @Sendable () throws -> Void
    ) {
        stateLock.lock()
        guard lifecycle == .acceptingWrites else {
            stateLock.unlock()
            onError(CSVMeasurementLoggerError.notStarted)
            return
        }
        guard pendingWriteCount < maximumPendingWrites else {
            overflowedWriteCount += 1
            stateLock.unlock()
            onError(CSVMeasurementLoggerError.queueOverflow(capacity: maximumPendingWrites))
            return
        }
        pendingWriteCount += 1
        stateLock.unlock()
        queue.async { [self] in
            defer {
                stateLock.lock()
                pendingWriteCount -= 1
                stateLock.unlock()
            }
            guard fileHandle != nil else { return }
            do {
                try writePendingOverflowIfNeeded()
                try operation()
            } catch {
                if !(error is CSVMeasurementLoggerError) { _ = closeFile() }
                guard !errorReported else { return }
                errorReported = true
                onError(error)
            }
        }
    }

    private func requireSession(_ sessionID: UUID) throws -> MeasurementSession {
        guard let activeSession else { throw CSVMeasurementLoggerError.notStarted }
        guard activeSession.id == sessionID else {
            throw CSVMeasurementLoggerError.sessionMismatch(expected: activeSession.id, actual: sessionID)
        }
        return activeSession
    }

    private func writePendingOverflowIfNeeded() throws {
        stateLock.lock()
        let count = overflowedWriteCount
        overflowedWriteCount = 0
        stateLock.unlock()
        guard count > 0, let session = activeSession else { return }
        try write(Self.errorLine(
            sessionID: session.id,
            status: session.status,
            timestamp: Date(),
            type: .bufferOverflow,
            message: "Dropped \(count) logger write request(s); queue capacity \(maximumPendingWrites)."
        ))
    }

    private func write(_ line: String, synchronize: Bool = true) throws {
        guard let fileHandle else { throw CSVMeasurementLoggerError.notStarted }
        try fileHandle.write(contentsOf: Data(line.utf8))
        writesSinceSynchronization += 1
        if synchronize, writesSinceSynchronization >= synchronizationInterval {
            try fileHandle.synchronize()
            writesSinceSynchronization = 0
        }
    }

    private func closeFile() -> Result<Void, Error> {
        guard let fileHandle else { return .success(()) }
        var firstError: Error?
        do { try fileHandle.synchronize() } catch { firstError = error }
        do { try fileHandle.close() } catch { if firstError == nil { firstError = error } }
        self.fileHandle = nil
        writesSinceSynchronization = 0
        return firstError.map { .failure($0) } ?? .success(())
    }

    private static func legacyLine(_ record: CSVMeasurementRecord, session: MeasurementSession?) -> String {
        var fields = emptyFields()
        fields[.timestamp] = timestamp(record.timestamp)
        fields[.laeq1Minute] = number(record.laeq1)
        fields[.laeq10Minutes] = number(record.laeq10)
        fields[.laeq15Minutes] = number(record.laeq15)
        fields[.lceq1Minute] = number(record.lceq1)
        fields[.lceq10Minutes] = number(record.lceq10)
        fields[.aSlow] = number(record.aSlow)
        fields[.cSlow] = number(record.cSlow)
        fields[.lcPeak] = number(record.lcPeak)
        fields[.lafMax] = number(record.lafMax)
        fields[.cMinusA1Minute] = number(record.cMinusA1)
        fields[.cMinusA10Minutes] = number(record.cMinusA10)
        fields[.cMinusASlow] = number(record.cMinusASlow)
        fields[.inputDeviceUID] = escaped(record.deviceUID)
        fields[.inputChannel] = String(record.channel + 1)
        fields[.calibrationOffset] = number(record.calibrationOffset)
        fields[.calibratedAt] = timestamp(record.calibratedAt)
        fields[.rowType] = RowType.legacySample.rawValue
        fields[.timestampUTC] = timestamp(record.timestamp)
        if let session {
            fields[.sessionID] = session.id.uuidString
            fields[.sessionStatus] = session.status.rawValue
        }
        return line(fields)
    }

    private static func sampleLine(_ sample: MeasurementSample, session: MeasurementSession) -> String {
        var fields = emptyFields()
        fields[.timestamp] = timestamp(sample.timestamp)
        fields[.laeq1Minute] = number(sample.laeq1Minute)
        fields[.laeq10Minutes] = number(sample.laeq10Minutes)
        fields[.laeq15Minutes] = number(sample.laeq15Minutes)
        fields[.lceq1Minute] = number(sample.lceq1Minute)
        fields[.lceq10Minutes] = number(sample.lceq10Minutes)
        fields[.aSlow] = number(sample.aSlow)
        fields[.cSlow] = number(sample.cSlow)
        fields[.lcPeak] = number(sample.lcPeak1Second)
        fields[.lafMax] = number(sample.lafMax1Second)
        fields[.cMinusA1Minute] = number(sample.cMinusA1Minute)
        fields[.cMinusA10Minutes] = number(sample.cMinusA10Minutes)
        fields[.cMinusASlow] = number(sample.cMinusASlow)
        fields[.inputDeviceUID] = escaped(session.deviceUID)
        fields[.inputChannel] = String(session.channel + 1)
        fields[.calibrationOffset] = number(session.calibrationOffset)
        fields[.calibratedAt] = timestamp(session.calibratedAt)
        fields[.rowType] = RowType.sample.rawValue
        fields[.timestampUTC] = timestamp(sample.timestamp)
        fields[.sessionID] = session.id.uuidString
        fields[.sessionStatus] = session.status.rawValue
        fields[.measurementState] = sample.state.rawValue
        fields[.measurementStateReason] = escaped(sample.stateReason ?? defaultStateReason(for: sample))
        fields[.completedSecondCount] = String(sample.completedSecondCount)
        fields[.processedFrameCount] = String(sample.processedFrameCount)
        fields[.laeq1Second] = number(sample.laeq1Second)
        fields[.lceq1Second] = number(sample.lceq1Second)
        fields[.lzeq1Second] = number(sample.lzeq1Second)
        fields[.lafMax1Second] = number(sample.lafMax1Second)
        fields[.lasMax1Second] = number(sample.lasMax1Second)
        fields[.lcPeak1Second] = number(sample.lcPeak1Second)
        fields[.laeq30Minutes] = number(sample.laeq30Minutes)
        fields[.lceq30Minutes] = number(sample.lceq30Minutes)
        return line(fields)
    }

    private static func sessionLine(_ session: MeasurementSession, timestamp rowTimestamp: Date) -> String {
        var fields = emptyFields()
        fields[.timestamp] = timestamp(rowTimestamp)
        fields[.inputDeviceUID] = escaped(session.deviceUID)
        fields[.inputChannel] = String(session.channel + 1)
        fields[.calibrationOffset] = number(session.calibrationOffset)
        fields[.calibratedAt] = timestamp(session.calibratedAt)
        fields[.rowType] = RowType.session.rawValue
        fields[.timestampUTC] = timestamp(rowTimestamp)
        fields[.sessionID] = session.id.uuidString
        fields[.sessionStatus] = session.status.rawValue
        fields[.sessionStartedAtUTC] = timestamp(session.startedAt)
        fields[.sessionEndedAtUTC] = session.endedAt.map(timestamp) ?? ""
        fields[.sessionName] = escaped(session.name)
        fields[.measurementLocation] = escaped(session.location)
        fields[.sessionNote] = escaped(session.note ?? "")
        fields[.microphoneID] = escaped(session.microphoneID ?? "")
        fields[.sampleRateHz] = preciseNumber(session.sampleRate)
        fields[.appVersion] = escaped(session.appVersion)
        fields[.measurementConfigurationJSON] = escaped(json(session.measurementConfiguration))
        return line(fields)
    }

    private static func eventLine(_ event: MeasurementEvent, sessionStatus: MeasurementSessionStatus) -> String {
        var fields = emptyFields()
        fields[.timestamp] = timestamp(event.timestamp)
        fields[.rowType] = RowType.event.rawValue
        fields[.timestampUTC] = timestamp(event.timestamp)
        fields[.sessionID] = event.sessionID.uuidString
        fields[.sessionStatus] = sessionStatus.rawValue
        fields[.eventID] = event.id.uuidString
        fields[.eventType] = event.type.rawValue
        fields[.eventMetadataJSON] = escaped(json(event.metadata))
        return line(fields)
    }

    private static func gapLine(_ gap: MeasurementGap, sessionStatus: MeasurementSessionStatus) -> String {
        var fields = emptyFields()
        fields[.timestamp] = timestamp(gap.startedAt)
        fields[.rowType] = RowType.gap.rawValue
        fields[.timestampUTC] = timestamp(gap.startedAt)
        fields[.sessionID] = gap.sessionID.uuidString
        fields[.sessionStatus] = sessionStatus.rawValue
        fields[.measurementState] = "Gap"
        fields[.gapStartedAtUTC] = timestamp(gap.startedAt)
        fields[.gapEndedAtUTC] = timestamp(gap.endedAt)
        fields[.lostSecondIntervals] = String(gap.lostSecondIntervals)
        fields[.eventType] = MeasurementEventType.audioDropout.rawValue
        fields[.eventMetadataJSON] = escaped(json(["reason": gap.reason]))
        return line(fields)
    }

    private static func errorLine(
        sessionID: UUID,
        status: MeasurementSessionStatus,
        timestamp rowTimestamp: Date,
        type: MeasurementEventType,
        message: String
    ) -> String {
        var fields = emptyFields()
        fields[.timestamp] = timestamp(rowTimestamp)
        fields[.rowType] = RowType.error.rawValue
        fields[.timestampUTC] = timestamp(rowTimestamp)
        fields[.sessionID] = sessionID.uuidString
        fields[.sessionStatus] = status.rawValue
        fields[.measurementState] = "Error"
        fields[.eventType] = type.rawValue
        fields[.eventMetadataJSON] = escaped(json(["message": message]))
        return line(fields)
    }

    private static func emptyFields() -> [String] { Array(repeating: "", count: Column.allCases.count) }
    private static func line(_ fields: [String]) -> String { fields.joined(separator: ",") + "\n" }

    private static func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func preciseNumber(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func defaultStateReason(for sample: MeasurementSample) -> String {
        sample.state == .invalid ? "One or more mandatory metrics unavailable" : ""
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter.string(
            from: date,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            formatOptions: [.withInternetDateTime, .withFractionalSeconds]
        )
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private static func json(_ value: [String: String]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    private static func escaped(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func parseCSV(_ contents: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var insideQuotes = false
        var index = contents.startIndex
        while index < contents.endIndex {
            let character = contents[index]
            if character == "\"" {
                let next = contents.index(after: index)
                if insideQuotes, next < contents.endIndex, contents[next] == "\"" {
                    field.append("\"")
                    index = contents.index(after: next)
                    continue
                }
                insideQuotes.toggle()
            } else if character == ",", !insideQuotes {
                row.append(field)
                field = ""
            } else if character == "\n", !insideQuotes {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else if character != "\r" || insideQuotes {
                field.append(character)
            }
            index = contents.index(after: index)
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

private extension Array where Element == String {
    subscript(_ column: CSVMeasurementLogger.Column) -> String {
        get { self[column.rawValue] }
        set { self[column.rawValue] = newValue }
    }
}
