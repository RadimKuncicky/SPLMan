import Foundation

struct RecordingEventHistoryEntry: Identifiable, Sendable {
    private static let audioDiscontinuityExpression = try? NSRegularExpression(
        pattern: #"^Audio input discontinuity \(events ([0-9]+), missing frames ([0-9]+), discarded partial frames ([0-9]+), UTC delta ([0-9.+-]+) s\)$"#
    )

    let id: String
    let timestamp: Date
    let type: String
    let metadata: [String: String]

    var title: String {
        switch type {
        case "RecordingStarted": L10n.text("Záznam spuštěn")
        case "RecordingStopped": L10n.text("Záznam ukončen")
        case "RecordingPaused": L10n.text("Záznam pozastaven")
        case "RecordingResumed": L10n.text("Záznam obnoven")
        case "CalibrationChanged": L10n.text("Změna kalibrace")
        case "AudioDeviceChanged": L10n.text("Změna audio zařízení")
        case "SampleRateChanged": L10n.text("Změna vzorkovací frekvence")
        case "InputGainChanged": L10n.text("Změna vstupního zisku")
        case "AudioDropout": L10n.text("Výpadek audia")
        case "BufferOverflow": L10n.text("Přetečení bufferu")
        case "ClippingDetected": L10n.text("Detekován clipping")
        case "AlarmTriggered": L10n.text("Alarm aktivován")
        case "AlarmCleared": L10n.text("Alarm ukončen")
        case "ConfigurationChanged": L10n.text("Změna konfigurace")
        case "StorageError": L10n.text("Chyba úložiště")
        case "ApplicationInterrupted": L10n.text("Aplikace přerušena")
        default: type
        }
    }

    var metadataDetail: String {
        metadata.keys.sorted().map { key in
            let value = metadata[key] ?? ""
            return "\(Self.localizedMetadataKey(key)): \(Self.localizedMetadataValue(value, for: key))"
        }.joined(separator: " · ")
    }

    private static func localizedMetadataKey(_ key: String) -> String {
        switch key {
        case "final_status": L10n.text("Stav relace")
        case "reason": L10n.text("Důvod")
        case "message": L10n.text("Zpráva")
        case "displayed_metrics": L10n.text("Zobrazená měření")
        case "alarm_enabled": L10n.text("Alarmy zapnuty")
        case "laeq_30_min_limit_db": L10n.text("Limit LAeq 30 min")
        case "lcpeak_limit_db": L10n.text("Limit LCpeak")
        case "metric": L10n.text("Metrika")
        case "clipped_frame_count": L10n.text("Oříznuté snímky")
        case "audio_dropout_count": L10n.text("Výpadky audia")
        case "render_error_count": L10n.text("Chyby zpracování audia")
        case "missing_frame_count": L10n.text("Chybějící snímky")
        case "discarded_partial_frame_count": L10n.text("Zahozené neúplné snímky")
        case "last_render_status": L10n.text("Poslední stav zpracování")
        case "dropped_second_interval_count": L10n.text("Zahozené sekundové intervaly")
        case "limit_db": L10n.text("Limit")
        case "value_db": L10n.text("Hodnota")
        case "previous_device_uid": L10n.text("Předchozí UID zařízení")
        case "new_device_uid": L10n.text("Nové UID zařízení")
        case "setting": L10n.text("Nastavení")
        case "previous_value": L10n.text("Předchozí hodnota")
        case "new_value": L10n.text("Nová hodnota")
        case "detail": L10n.text("Detail")
        default: key
        }
    }

    private static func localizedMetadataValue(_ value: String, for key: String) -> String {
        switch key {
        case "metric":
            return Metric(rawValue: value)?.title ?? value
        case "displayed_metrics":
            return value.split(separator: ";", omittingEmptySubsequences: false)
                .map { Metric(rawValue: String($0))?.title ?? String($0) }
                .joined(separator: "; ")
        case "setting" where value == "input_channel":
            return L10n.text("Vstupní kanál")
        case "alarm_enabled" where value == "true":
            return L10n.text("Ano")
        case "alarm_enabled" where value == "false":
            return L10n.text("Ne")
        case "final_status":
            return localizedSessionStatus(value)
        case "reason":
            return localizedReason(value)
        default:
            return value
        }
    }

    private static func localizedSessionStatus(_ value: String) -> String {
        switch value {
        case "Created": L10n.text("Vytvořeno")
        case "Recording": L10n.text("Probíhá")
        case "Paused": L10n.text("Pozastaveno")
        case "Completed": L10n.text("Dokončeno")
        case "Interrupted": L10n.text("Přerušeno")
        case "Failed": L10n.text("Selhalo")
        default: value
        }
    }

    private static func localizedReason(_ value: String) -> String {
        switch value {
        case "Metric unavailable":
            return L10n.text("Metrika není dostupná")
        case "Alarm monitoring disabled":
            return L10n.text("Monitorování alarmů bylo vypnuto")
        case "Missing completed-second samples at recording start":
            return L10n.text("Při zahájení záznamu chyběly dokončené sekundové vzorky")
        case "Missing completed-second samples":
            return L10n.text("Chybějící dokončené sekundové vzorky")
        case "Initial partial second excluded after recording start":
            return L10n.text("Po zahájení záznamu byla vynechána počáteční neúplná sekunda")
        case "Digital silence or mandatory metric unavailable":
            return L10n.text("Digitální ticho nebo nedostupná povinná metrika")
        case "Completed-second buffer overflow":
            return L10n.text("Přetečení bufferu dokončených sekund")
        default:
            return localizedAudioDiscontinuity(value) ?? value
        }
    }

    private static func localizedAudioDiscontinuity(_ value: String) -> String? {
        guard let expression = audioDiscontinuityExpression,
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ), match.numberOfRanges == 5,
              let eventCount = unsignedCapture(1, match: match, value: value),
              let missingFrames = unsignedCapture(2, match: match, value: value),
              let discardedFrames = unsignedCapture(3, match: match, value: value),
              let deltaRange = Range(match.range(at: 4), in: value),
              let delta = Double(value[deltaRange]) else { return nil }
        return L10n.format(
            "Nespojitost zvukového vstupu (události %llu, chybějící snímky %llu, zahozené neúplné snímky %llu, rozdíl UTC %.6f s)",
            eventCount,
            missingFrames,
            discardedFrames,
            delta
        )
    }

    private static func unsignedCapture(
        _ index: Int,
        match: NSTextCheckingResult,
        value: String
    ) -> UInt64? {
        guard let range = Range(match.range(at: index), in: value) else { return nil }
        return UInt64(value[range])
    }
}

struct RecordingEventHistoryResult: Sendable {
    let events: [RecordingEventHistoryEntry]
    let isTruncated: Bool
}

enum RecordingEventHistoryReader {
    private static let chunkSize = 64 * 1_024

    static func readEvents(
        at url: URL,
        sessionID: UUID,
        limit: Int = 100
    ) throws -> RecordingEventHistoryResult {
        let retainedLimit = max(1, limit)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var parser = StreamingCSVParser()
        var columns: [String: Int]?
        var retained: [RecordingEventHistoryEntry] = []
        var totalEventCount = 0
        var rowNumber = 0
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        func consume(_ rows: [[String]]) {
            for row in rows {
                rowNumber += 1
                guard let existingColumns = columns else {
                    columns = Dictionary(uniqueKeysWithValues: row.enumerated().map { ($1, $0) })
                    continue
                }
                guard let rowType = value("row_type", in: row, columns: existingColumns),
                      ["event", "gap", "error"].contains(rowType),
                      value("session_id", in: row, columns: existingColumns) == sessionID.uuidString,
                      let timestampText = value("timestamp_utc", in: row, columns: existingColumns),
                      let timestamp = formatter.date(from: timestampText),
                      let type = value("event_type", in: row, columns: existingColumns),
                      !type.isEmpty else { continue }

                let eventID = value("event_id", in: row, columns: existingColumns)
                let metadataText = value("event_metadata_json", in: row, columns: existingColumns) ?? "{}"
                let stableID = eventID.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "\(rowNumber)-\(timestampText)-\(type)"
                let entry = RecordingEventHistoryEntry(
                    id: stableID,
                    timestamp: timestamp,
                    type: type,
                    metadata: metadata(from: metadataText)
                )
                totalEventCount += 1
                retained.append(entry)
                if retained.count > retainedLimit { retained.removeFirst() }
            }
        }

        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
            consume(try parser.consume(data))
        }
        consume(try parser.finish())

        return RecordingEventHistoryResult(
            events: retained.reversed(),
            isTruncated: totalEventCount > retainedLimit
        )
    }

    private static func value(
        _ name: String,
        in row: [String],
        columns: [String: Int]
    ) -> String? {
        guard let index = columns[name], row.indices.contains(index) else { return nil }
        return row[index]
    }

    private static func metadata(from value: String) -> [String: String] {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let metadata = object as? [String: String] else {
            return value.isEmpty ? [:] : ["detail": value]
        }
        return metadata
    }
}

private struct StreamingCSVParser {
    private enum State { case unquoted, quoted, afterQuote }
    private static let maximumFieldSize = 1_048_576

    private var state = State.unquoted
    private var field: [UInt8] = []
    private var row: [String] = []

    mutating func consume(_ data: Data) throws -> [[String]] {
        var rows: [[String]] = []
        for byte in data {
            switch state {
            case .unquoted:
                switch byte {
                case 34 where field.isEmpty:
                    state = .quoted
                case 44:
                    finishField()
                case 10:
                    finishRow(into: &rows)
                case 13:
                    break
                default:
                    try append(byte)
                }
            case .quoted:
                if byte == 34 {
                    state = .afterQuote
                } else {
                    try append(byte)
                }
            case .afterQuote:
                switch byte {
                case 34:
                    try append(byte)
                    state = .quoted
                case 44:
                    finishField()
                    state = .unquoted
                case 10:
                    finishRow(into: &rows)
                    state = .unquoted
                case 13:
                    break
                default:
                    try append(byte)
                    state = .unquoted
                }
            }
        }
        return rows
    }

    mutating func finish() throws -> [[String]] {
        guard state != .quoted else { throw RecordingEventHistoryError.incompleteCSV }
        guard !field.isEmpty || !row.isEmpty else { return [] }
        var rows: [[String]] = []
        finishRow(into: &rows)
        return rows
    }

    private mutating func append(_ byte: UInt8) throws {
        guard field.count < Self.maximumFieldSize else {
            throw RecordingEventHistoryError.fieldTooLarge
        }
        field.append(byte)
    }

    private mutating func finishField() {
        row.append(String(decoding: field, as: UTF8.self))
        field.removeAll(keepingCapacity: true)
    }

    private mutating func finishRow(into rows: inout [[String]]) {
        finishField()
        rows.append(row)
        row.removeAll(keepingCapacity: true)
    }
}

enum RecordingEventHistoryError: LocalizedError {
    case incompleteCSV
    case fieldTooLarge

    var errorDescription: String? {
        switch self {
        case .incompleteCSV: L10n.text("CSV záznam končí uvnitř neuzavřeného pole.")
        case .fieldTooLarge: L10n.text("Jedno pole CSV překročilo bezpečný limit pro zobrazení historie.")
        }
    }
}
