import Foundation

enum SelfTest {
    private final class AsyncErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var error: Error?

        func store(_ error: Error) {
            lock.lock()
            self.error = error
            lock.unlock()
        }

        func load() -> Error? {
            lock.lock()
            defer { lock.unlock() }
            return error
        }
    }

    static func run() -> Bool {
        var failures: [String] = []
        testRollingEnergy(&failures)
        testFifteenMinuteRollingEnergy(&failures)
        testCalibration(&failures)
        testSettingsCoding(&failures)
        testThresholds(&failures)
        testToneDetector(&failures)
        testWeightingResponses(&failures)
        testIntersamplePeak(&failures)
        testFastAndMaximumLevels(&failures)
        testCSVLogging(&failures)
        testRecordingErrorPersistence(&failures)
        testRecordingHistoryPersistence(&failures)
        testRecordingIntervalBoundary(&failures)
        testDisplayedAudioDropoutCount(&failures)
        testDiscontinuityGapTiming(&failures)
        testRecordingEventHistory(&failures)
        failures.append(contentsOf: LocalizationValidation.run())
        if !DSPValidation.run() {
            failures.append("DSP validation suite failed")
        }
        failures.append(contentsOf: LoggingIntegrityTests.run())

        if failures.isEmpty {
            print("SPLMan self-test: PASS")
            return true
        }
        print("SPLMan self-test: FAIL")
        failures.forEach { print("- \($0)") }
        return false
    }

    private static func testRollingEnergy(_ failures: inout [String]) {
        var rolling = RollingEnergy(capacity: 3)
        rolling.append(1)
        rolling.append(2)
        if rolling.average != nil { failures.append("Rolling window published before full") }
        rolling.append(3)
        if abs((rolling.average ?? 0) - 2) > 1e-9 { failures.append("Rolling mean is incorrect") }
        rolling.append(7)
        if abs((rolling.average ?? 0) - 4) > 1e-9 { failures.append("Rolling eviction is incorrect") }
    }

    private static func testFifteenMinuteRollingEnergy(_ failures: inout [String]) {
        var rolling = RollingEnergy(capacity: 9_000)
        for _ in 0..<8_999 {
            rolling.append(1)
        }
        if rolling.average != nil {
            failures.append("15-minute window published before full")
        }
        rolling.append(1)
        if abs((rolling.average ?? 0) - 1) > 1e-12 {
            failures.append("15-minute window did not publish when full")
        }
        rolling.append(10)
        let expected = (8_999.0 + 10.0) / 9_000.0
        if abs((rolling.average ?? 0) - expected) > 1e-12 {
            failures.append("15-minute rolling eviction is incorrect")
        }
    }

    private static func testFastAndMaximumLevels(_ failures: inout [String]) {
        let sampleRate = 48_000.0
        let quiet = sineWave(amplitude: 0.01, duration: 1, sampleRate: sampleRate)
        let loud = sineWave(amplitude: 0.5, duration: 0.1, sampleRate: sampleRate)
        let processor = SPLProcessor(sampleRate: sampleRate)
        _ = quiet.withUnsafeBufferPointer {
            processor.process($0.baseAddress!, count: $0.count)
        }
        let loudSnapshot = loud.withUnsafeBufferPointer {
            processor.process($0.baseAddress!, count: $0.count)
        }
        guard let loudSnapshot,
              let fastMaximum = loudSnapshot.lafMax,
              let slow = loudSnapshot.aSlow,
              let peakMaximum = loudSnapshot.lcPeak else {
            failures.append("Fast/peak maximum levels were not produced")
            return
        }
        if fastMaximum <= slow {
            failures.append("Fast response did not rise above Slow after a short level increase")
        }

        let quietAfterLoud = quiet.withUnsafeBufferPointer {
            processor.process($0.baseAddress!, count: $0.count)
        }
        if abs((quietAfterLoud?.lafMax ?? -.infinity) - fastMaximum) > 1e-9 {
            failures.append("LAFmax decreased without a processor reset")
        }
        if abs((quietAfterLoud?.lcPeak ?? -.infinity) - peakMaximum) > 1e-9 {
            failures.append("LCpeak decreased without a processor reset")
        }

        let resetProcessor = SPLProcessor(sampleRate: sampleRate)
        let resetSnapshot = quiet.withUnsafeBufferPointer {
            resetProcessor.process($0.baseAddress!, count: $0.count)
        }
        if (resetSnapshot?.lafMax ?? .infinity) >= fastMaximum - 10 {
            failures.append("LAFmax was not reset with a new processor")
        }
        if (resetSnapshot?.lcPeak ?? .infinity) >= peakMaximum - 10 {
            failures.append("LCpeak was not reset with a new processor")
        }
    }

    private static func testIntersamplePeak(_ failures: inout [String]) {
        let sampleRate = 48_000.0
        let frequency = 16_000.0
        let amplitude = 0.5
        var sampledPeak = 0.0
        var detector = FourTimesIntersamplePeakDetector()
        for index in 0..<Int(sampleRate * 0.1) {
            let sample = amplitude * sin(2 * Double.pi * frequency * Double(index) / sampleRate)
            sampledPeak = max(sampledPeak, abs(sample))
            detector.process(sample)
        }
        if detector.maximumAmplitude < sampledPeak * 1.08 {
            failures.append("4x peak detector did not recover a high-frequency inter-sample peak")
        }
        if abs(detector.maximumAmplitude - amplitude) > amplitude * 0.08 {
            failures.append("4x peak interpolation exceeded its high-frequency accuracy tolerance")
        }
    }

    private static func sineWave(
        amplitude: Double,
        duration: Double,
        sampleRate: Double
    ) -> [Float] {
        (0..<Int(duration * sampleRate)).map { index in
            Float(amplitude * sin(2 * Double.pi * 1_000 * Double(index) / sampleRate))
        }
    }

    private static func testCalibration(_ failures: inout [String]) {
        var stable = CalibrationSession()
        var stableResult: CalibrationSession.Result = .collecting(progress: 0)
        for index in 0..<CalibrationSession.requiredSamples {
            let level = -20 + (index.isMultiple(of: 2) ? 0.1 : -0.1)
            stableResult = stable.add(
                rawASlowDB: level,
                rawCSlowDB: level,
                toneConcentration: 0.95
            )
        }
        if case let .calibrated(offset) = stableResult {
            if abs(offset - 114) > 0.02 { failures.append("Calibration offset is incorrect") }
        } else {
            failures.append("Stable calibration was rejected")
        }

        var unstable = CalibrationSession()
        var unstableResult: CalibrationSession.Result = .collecting(progress: 0)
        for index in 0..<CalibrationSession.maximumSamples {
            let level = index.isMultiple(of: 2) ? -24.0 : -20.0
            unstableResult = unstable.add(
                rawASlowDB: level,
                rawCSlowDB: level,
                toneConcentration: 0.95
            )
        }
        if case .unstable = unstableResult {} else {
            failures.append("Unstable calibration was accepted")
        }

        var wrongTone = CalibrationSession()
        var wrongToneResult: CalibrationSession.Result = .collecting(progress: 0)
        for _ in 0..<CalibrationSession.maximumSamples {
            wrongToneResult = wrongTone.add(
                rawASlowDB: -20,
                rawCSlowDB: -20,
                toneConcentration: 0.05
            )
        }
        if case .invalidSignal = wrongToneResult {} else {
            failures.append("Non-1 kHz signal was accepted for calibration")
        }
    }

    private static func testCSVLogging(_ failures: inout [String]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SPLManSelfTest-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("measurement.csv")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            failures.append("CSV test directory could not be created")
            return
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let logger = CSVMeasurementLogger()
        let startFinished = DispatchSemaphore(value: 0)
        let startError = AsyncErrorBox()
        logger.start(at: file) { result in
            if case let .failure(error) = result { startError.store(error) }
            startFinished.signal()
        }
        guard startFinished.wait(timeout: .now() + 2) == .success, startError.load() == nil else {
            failures.append("CSV logger did not create its file")
            return
        }

        let appendError = AsyncErrorBox()
        logger.append(CSVMeasurementRecord(
            timestamp: Date(timeIntervalSince1970: 1_000),
            laeq1: 72.3,
            laeq10: nil,
            laeq15: 74.5,
            lceq1: 76.1,
            lceq10: nil,
            aSlow: 73,
            cSlow: 77,
            lcPeak: 101.2,
            lafMax: 88.4,
            cMinusA1: 3.8,
            cMinusA10: nil,
            cMinusASlow: 4,
            deviceUID: "device,\"quoted\"",
            channel: 1,
            calibrationOffset: 114.2,
            calibratedAt: Date(timeIntervalSince1970: 900)
        )) { error in
            appendError.store(error)
        }

        let stopFinished = DispatchSemaphore(value: 0)
        let stopError = AsyncErrorBox()
        logger.stop { result in
            if case let .failure(error) = result { stopError.store(error) }
            stopFinished.signal()
        }
        guard stopFinished.wait(timeout: .now() + 2) == .success,
              stopError.load() == nil,
              appendError.load() == nil else {
            failures.append("CSV logger did not flush and close cleanly")
            return
        }

        do {
            let contents = try String(contentsOf: file, encoding: .utf8)
            if !contents.hasPrefix("timestamp,laeq_1_min_db,laeq_10_min_db,laeq_15_min_db") {
                failures.append("CSV header is missing fixed metric columns")
            }
            if !contents.contains(",72.3,,74.5,") {
                failures.append("CSV did not preserve a missing metric as an empty field")
            }
            if !contents.contains("\"device,\"\"quoted\"\"\"") {
                failures.append("CSV did not escape device metadata")
            }
            if contents.split(separator: "\n").count != 2 {
                failures.append("CSV lifecycle test did not produce one complete data row")
            }
        } catch {
            failures.append("CSV output could not be read after close")
        }
    }

    private static func testRecordingErrorPersistence(_ failures: inout [String]) {
        let suiteName = "SPLManSelfTest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            failures.append("Recording error test defaults could not be created")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RecordingErrorStore(defaults: defaults)
        store.save("flush failed")
        if store.load() != "flush failed" {
            failures.append("Recording close error was not persisted")
        }
        store.clear()
        if store.load() != nil {
            failures.append("Acknowledged recording error remained persisted")
        }
    }

    private static func testRecordingHistoryPersistence(_ failures: inout [String]) {
        let suiteName = "SPLManHistorySelfTest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            failures.append("Recording history test defaults could not be created")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RecordingHistoryStore(defaults: defaults)
        let metadata = RecordingMetadataDraft(
            eventName: "Concert",
            location: "Hall",
            note: "Front of house",
            microphoneID: "Mic 1"
        )
        store.saveMetadata(metadata)
        if store.loadMetadata() != metadata {
            failures.append("Recording metadata persistence did not round-trip")
        }
        let alarmSettings = AlarmSettings(
            isEnabled: false,
            laeq30MinuteLimit: 98.5,
            lcPeakLimit: 132
        )
        store.saveAlarmSettings(alarmSettings)
        if store.loadAlarmSettings() != alarmSettings {
            failures.append("Alarm settings persistence did not round-trip")
        }

        let entry = RecordingHistoryEntry(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: nil,
            eventName: metadata.eventName,
            location: metadata.location,
            filePath: "/tmp/measurement.csv",
            state: .recording
        )
        store.saveHistory([entry])
        let restored = store.loadHistory()
        if restored.count != 1 || restored[0].state != .interrupted || restored[0].endedAt == nil {
            failures.append("Unfinished recording was not marked as interrupted on restore")
        }
    }

    private static func testRecordingIntervalBoundary(_ failures: inout [String]) {
        let startedAt = Date(timeIntervalSince1970: 1_000.5)
        if CompletedSecondRecorder.isFullIntervalAfterRecordingStart(
            intervalEndUTC: Date(timeIntervalSince1970: 1_001),
            sessionStartedAt: startedAt
        ) {
            failures.append("A pre-REC partial second was accepted for logging")
        }
        if !CompletedSecondRecorder.isFullIntervalAfterRecordingStart(
            intervalEndUTC: Date(timeIntervalSince1970: 1_001.5),
            sessionStartedAt: startedAt
        ) {
            failures.append("The first full post-REC second was rejected")
        }
    }

    private static func testDisplayedAudioDropoutCount(_ failures: inout [String]) {
        let queueOverflowOnly = AudioCaptureHealth(
            sampleRate: 48_000,
            processedFrameCount: 1,
            clippedFrameCount: 0,
            renderErrorCount: 0,
            audioDropoutCount: 0,
            missingFrameCount: 0,
            discardedPartialFrameCount: 0,
            droppedSecondIntervalCount: 37,
            lastRenderStatus: nil
        )
        if MeterModel.displayedAudioDropoutIncrement(queueOverflowOnly) != 0 {
            failures.append("Pre-record completed-second overflow was displayed as an audio dropout")
        }

        let realAudioFailures = AudioCaptureHealth(
            sampleRate: 48_000,
            processedFrameCount: 1,
            clippedFrameCount: 0,
            renderErrorCount: 2,
            audioDropoutCount: 3,
            missingFrameCount: 512,
            discardedPartialFrameCount: 256,
            droppedSecondIntervalCount: 37,
            lastRenderStatus: -1
        )
        if MeterModel.displayedAudioDropoutIncrement(realAudioFailures) != 5 {
            failures.append("Real audio dropouts and render errors were not displayed")
        }
    }

    private static func testDiscontinuityGapTiming(_ failures: inout [String]) {
        let sessionID = UUID()
        let sessionStart = Date(timeIntervalSince1970: 1_000)
        let forward = CompletedSecondRecorder.makeDiscontinuityGap(
            sessionID: sessionID,
            lastIntervalEnd: Date(timeIntervalSince1970: 1_010),
            nextIntervalStart: Date(timeIntervalSince1970: 1_012.25),
            sessionStartedAt: sessionStart,
            eventCount: 1,
            missingFrameCount: 4_800,
            discardedPartialFrameCount: 24_000
        )
        if forward.startedAt != Date(timeIntervalSince1970: 1_010)
            || forward.endedAt != Date(timeIntervalSince1970: 1_012.25)
            || forward.lostSecondIntervals != 3 {
            failures.append("Forward audio discontinuity gap has incorrect UTC bounds")
        }
        if !forward.reason.contains("discarded partial frames 24000") {
            failures.append("Audio discontinuity gap omitted discarded-frame diagnostics")
        }

        let backward = CompletedSecondRecorder.makeDiscontinuityGap(
            sessionID: sessionID,
            lastIntervalEnd: Date(timeIntervalSince1970: 1_020),
            nextIntervalStart: Date(timeIntervalSince1970: 1_019),
            sessionStartedAt: sessionStart,
            eventCount: 1,
            missingFrameCount: 0,
            discardedPartialFrameCount: 1_024
        )
        if backward.startedAt != Date(timeIntervalSince1970: 1_020)
            || backward.endedAt != Date(timeIntervalSince1970: 1_019)
            || backward.lostSecondIntervals != 1 {
            failures.append("Backward audio clock reset was not preserved as an explicit gap")
        }
    }

    private static func testRecordingEventHistory(_ failures: inout [String]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SPLManEventHistory-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("measurement.csv")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            failures.append("Event history test directory could not be created")
            return
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = MeasurementSession(
            startedAt: Date(timeIntervalSince1970: 5_000),
            name: "History test",
            location: "Test lab",
            deviceUID: "device",
            channel: 0,
            sampleRate: 48_000,
            calibrationOffset: 100,
            calibratedAt: Date(timeIntervalSince1970: 4_900),
            appVersion: "test"
        )
        let logger = CSVMeasurementLogger()
        let started = DispatchSemaphore(value: 0)
        let errors = AsyncErrorBox()
        logger.start(at: file, session: session) { result in
            if case let .failure(error) = result { errors.store(error) }
            started.signal()
        }
        guard started.wait(timeout: .now() + 2) == .success, errors.load() == nil else {
            failures.append("Event history logger did not start")
            return
        }
        logger.append(MeasurementEvent(
            sessionID: session.id,
            timestamp: Date(timeIntervalSince1970: 5_001),
            type: .configurationChanged,
            metadata: ["detail": "comma, quote \" and newline\nvalue"]
        )) { errors.store($0) }
        logger.append(MeasurementEvent(
            sessionID: session.id,
            timestamp: Date(timeIntervalSince1970: 5_002),
            type: .clippingDetected,
            metadata: ["clipped_frame_count": "7"]
        )) { errors.store($0) }
        let flushed = DispatchSemaphore(value: 0)
        logger.flush { result in
            if case let .failure(error) = result { errors.store(error) }
            flushed.signal()
        }
        guard flushed.wait(timeout: .now() + 2) == .success, errors.load() == nil else {
            logger.stop(waitUntilClosed: true)
            failures.append("Event history CSV did not flush")
            return
        }

        do {
            let result = try RecordingEventHistoryReader.readEvents(
                at: file,
                sessionID: session.id,
                limit: 1
            )
            if !result.isTruncated || result.events.count != 1 {
                failures.append("Event history reader did not enforce its retention limit")
            } else if result.events[0].type != MeasurementEventType.clippingDetected.rawValue
                || result.events[0].metadata["clipped_frame_count"] != "7" {
                failures.append("Event history reader returned incorrect event details")
            }
            let fullResult = try RecordingEventHistoryReader.readEvents(
                at: file,
                sessionID: session.id,
                limit: 10
            )
            let configuration = fullResult.events.first {
                $0.type == MeasurementEventType.configurationChanged.rawValue
            }
            if configuration?.metadata["detail"] != "comma, quote \" and newline\nvalue" {
                failures.append("Event history reader did not preserve quoted multiline metadata")
            }

            let displayEntry = RecordingEventHistoryEntry(
                id: "display-test",
                timestamp: Date(),
                type: MeasurementEventType.configurationChanged.rawValue,
                metadata: [
                    "metric": "laeq30",
                    "displayed_metrics": "laeq30;lcPeak",
                    "alarm_enabled": "false",
                    "setting": "input_channel",
                    "reason": "Metric unavailable",
                    "unknown_key": "unknown_value"
                ]
            )
            let detail = displayEntry.metadataDetail
            if detail.contains("metric:") || detail.contains("displayed_metrics:")
                || detail.contains("alarm_enabled:") || detail.contains("input_channel")
                || !detail.contains("LAeq 30 min") || !detail.contains("LCpeak")
                || !detail.contains("unknown_key: unknown_value") {
                failures.append("Event history did not localize known metadata for display")
            }
            if displayEntry.metadata["metric"] != "laeq30" {
                failures.append("Event history display localization mutated persisted metadata")
            }
        } catch {
            failures.append("Event history reader failed: \(error.localizedDescription)")
        }
        logger.stop(waitUntilClosed: true)
    }

    private static func testThresholds(_ failures: inout [String]) {
        let thresholds = VisualThresholds()
        if thresholds.range(for: .aSlow) != 95...100 {
            failures.append("A-weighted concert thresholds changed")
        }
        if thresholds.range(for: .cSlow) != 105...110 {
            failures.append("C-weighted concert thresholds changed")
        }
    }

    private static func testSettingsCoding(_ failures: inout [String]) {
        let key = CalibrationKey(deviceUID: "test-device", channel: 2)
        var settings = PersistedSettings()
        settings.input = InputSelection(deviceUID: key.deviceUID, channel: key.channel)
        settings.calibrations[key] = CalibrationRecord(
            offsetDB: 112.3,
            calibratedAt: Date(timeIntervalSince1970: 100)
        )
        do {
            let encoded = try PropertyListEncoder().encode(settings)
            let decoded = try PropertyListDecoder().decode(PersistedSettings.self, from: encoded)
            if decoded != settings { failures.append("Settings persistence did not round-trip") }
        } catch {
            failures.append("Settings persistence failed: \(error.localizedDescription)")
        }
    }

    private static func testWeightingResponses(_ failures: inout [String]) {
        let sampleRates = [44_100.0, 48_000.0, 96_000.0]
        let frequencies = [31.5, 125.0, 1_000.0, 4_000.0, 8_000.0, 12_500.0, 16_000.0]
        for sampleRate in sampleRates {
            for frequency in frequencies {
                for kind in [FrequencyWeightingFilter.Kind.a, .c] {
                    let measured = measuredGain(kind: kind, frequency: frequency, sampleRate: sampleRate)
                    let expected = analogGain(kind: kind, frequency: frequency)
                    if !measured.isFinite || abs(measured - expected) > 0.8 {
                        failures.append(String(
                            format: "%@ weighting %.0f Hz @ %.1f kHz: %.2f dB, expected %.2f dB",
                            kind == .a ? "A" : "C", frequency, sampleRate / 1_000, measured, expected
                        ))
                    }
                }
            }
        }
    }

    private static func testToneDetector(_ failures: inout [String]) {
        let sampleRate = 48_000.0
        func concentration(frequency: Double) -> Double {
            let samples = (0..<Int(sampleRate)).map { index in
                Float(0.25 * sin(2 * Double.pi * frequency * Double(index) / sampleRate))
            }
            let processor = SPLProcessor(sampleRate: sampleRate)
            return samples.withUnsafeBufferPointer {
                processor.process($0.baseAddress!, count: $0.count)?.oneKilohertzConcentration ?? 0
            }
        }
        if concentration(frequency: 1_000) < 0.9 {
            failures.append("1 kHz calibrator tone was not detected")
        }
        if concentration(frequency: 125) > 0.1 {
            failures.append("Non-calibrator tone passed the 1 kHz detector")
        }
    }

    private static func measuredGain(
        kind: FrequencyWeightingFilter.Kind,
        frequency: Double,
        sampleRate: Double
    ) -> Double {
        var filter = FrequencyWeightingFilter(kind: kind, sampleRate: sampleRate)
        let sampleCount = Int(sampleRate)
        var inputEnergy = 0.0
        var outputEnergy = 0.0
        for index in 0..<sampleCount {
            let input = sin(2 * Double.pi * frequency * Double(index) / sampleRate)
            let output = filter.process(input)
            if index >= sampleCount / 2 {
                inputEnergy += input * input
                outputEnergy += output * output
            }
        }
        return 10 * log10(outputEnergy / inputEnergy)
    }

    private static func analogGain(kind: FrequencyWeightingFilter.Kind, frequency: Double) -> Double {
        let f1 = 20.598997
        let f2 = 107.65265
        let f3 = 737.86223
        let f4 = 12194.217
        let squared = frequency * frequency
        switch kind {
        case .a:
            let ratio = (f4 * f4 * squared * squared) /
                ((squared + f1 * f1) * sqrt((squared + f2 * f2) * (squared + f3 * f3)) * (squared + f4 * f4))
            return 20 * log10(ratio) + 1.9997
        case .c:
            let ratio = (f4 * f4 * squared) /
                ((squared + f1 * f1) * (squared + f4 * f4))
            return 20 * log10(ratio) + 0.0619
        }
    }
}
