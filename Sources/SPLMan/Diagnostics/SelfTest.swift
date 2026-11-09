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
        testSpectrogramAnalyzer(&failures)
        testSpectrogramTimeline(&failures)
        testTransferFunctionAnalyzer(&failures)
        testTransferFunctionSmoothing(&failures)
        testTransferFunctionDisplayState(&failures)
        testTransferFunctionTraceVector(&failures)
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
        testSequenceGapTiming(&failures)
        testTrailingLossAccounting(&failures)
        testRollingEnergyPrecision(&failures)
        testSettingsKeepCalibrationsOnPartialDecodeFailure(&failures)
        testRecordingEventHistory(&failures)
        failures.append(contentsOf: MixerTests.run())
        failures.append(contentsOf: WirelessTests.run())
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
        var settling = CalibrationSession()
        var settlingCalibrated = false
        defer {
            if !settlingCalibrated {
                failures.append("Calibration did not finish after the A-Slow settling transient")
            }
        }
        for index in 0..<(CalibrationSession.settlingSamples + CalibrationSession.requiredSamples) {
            // A-Slow rising from zero after the engine restart (10 Hz snapshots).
            let level = -20 + 10 * log10(1 - exp(-Double(index + 1) * 0.1))
            let result = settling.add(rawASlowDB: level, rawCSlowDB: level, toneConcentration: 0.95)
            if case let .calibrated(offset) = result {
                settlingCalibrated = true
                if abs(offset - 114) > 0.02 {
                    failures.append("Calibration accepted the A-Slow settling transient")
                }
                break
            }
        }

        var stable = CalibrationSession()
        var stableResult: CalibrationSession.Result = .collecting(progress: 0)
        for index in 0..<(CalibrationSession.settlingSamples + CalibrationSession.requiredSamples) {
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

    private static func testSequenceGapTiming(_ failures: inout [String]) {
        let sessionID = UUID()
        let midRecording = CompletedSecondRecorder.makeSequenceGap(
            sessionID: sessionID,
            lastIntervalEnd: Date(timeIntervalSince1970: 1_010),
            nextIntervalStart: Date(timeIntervalSince1970: 1_013),
            lostSecondIntervals: 3,
            atRecordingStart: false
        )
        if midRecording.startedAt != Date(timeIntervalSince1970: 1_010)
            || midRecording.endedAt != Date(timeIntervalSince1970: 1_013)
            || midRecording.lostSecondIntervals != 3
            || !midRecording.reason.contains("overflow") {
            failures.append("Mid-recording dropped intervals did not produce a bounded gap")
        }

        let atStart = CompletedSecondRecorder.makeSequenceGap(
            sessionID: sessionID,
            lastIntervalEnd: Date(timeIntervalSince1970: 1_012.5),
            nextIntervalStart: Date(timeIntervalSince1970: 1_013),
            lostSecondIntervals: 3,
            atRecordingStart: true
        )
        if atStart.startedAt != Date(timeIntervalSince1970: 1_012.5)
            || atStart.startedAt > atStart.endedAt {
            failures.append("Recording-start sequence gap began before the session")
        }
    }

    private static func testTrailingLossAccounting(_ failures: inout [String]) {
        func tail(
            lastDelivered: UInt64?,
            completed: UInt64,
            events: UInt64
        ) -> AudioStreamTail {
            AudioStreamTail(
                lastDeliveredCompletedSecondCount: lastDelivered,
                completedSecondCount: completed,
                pendingDiscontinuityEvents: events,
                pendingMissingFrames: events * 100,
                pendingDiscardedPartialFrames: events * 10
            )
        }

        let undelivered = CompletedSecondRecorder.trailingLoss(
            tail: tail(lastDelivered: 20, completed: 20, events: 2),
            lastTakenCompletedSecondCount: 20
        )
        if undelivered != CompletedSecondRecorder.TrailingLoss(
            discontinuityEvents: 2,
            missingFrames: 200,
            discardedPartialFrames: 20,
            droppedIntervals: 0
        ) {
            failures.append("Discontinuity after the last interval did not produce a trailing gap")
        }

        // A discontinuity attached to an interval delivered after the tail was
        // read is logged with that interval and must not be repeated.
        let attachedLater = CompletedSecondRecorder.trailingLoss(
            tail: tail(lastDelivered: 20, completed: 20, events: 1),
            lastTakenCompletedSecondCount: 21
        )
        if attachedLater != CompletedSecondRecorder.TrailingLoss() {
            failures.append("Discontinuity attached to a drained interval was logged twice")
        }

        let dropped = CompletedSecondRecorder.trailingLoss(
            tail: tail(lastDelivered: 20, completed: 23, events: 0),
            lastTakenCompletedSecondCount: 20
        )
        if dropped.droppedIntervals != 3 || dropped.discontinuityEvents != 0 {
            failures.append("Intervals dropped after the last drained one were not counted")
        }

        let staleTail = CompletedSecondRecorder.trailingLoss(
            tail: tail(lastDelivered: 18, completed: 19, events: 0),
            lastTakenCompletedSecondCount: 20
        )
        if staleTail.droppedIntervals != 0 {
            failures.append("A stale stream tail produced phantom dropped intervals")
        }
    }

    private static func testRollingEnergyPrecision(_ failures: inout [String]) {
        var rolling = RollingEnergy(capacity: 60)
        for index in 0..<60 { rolling.append(100 + Double(index) * 0.37) }
        for _ in 0..<60 { rolling.append(1e-10) }
        guard let average = rolling.average,
              abs(average - 1e-10) / 1e-10 < 1e-9 else {
            failures.append("Rolling energy kept cancellation error after loud intervals left the window")
            return
        }
    }

    private static func testSettingsKeepCalibrationsOnPartialDecodeFailure(
        _ failures: inout [String]
    ) {
        var settings = PersistedSettings()
        let key = CalibrationKey(deviceUID: "device", channel: 1)
        let record = CalibrationRecord(
            offsetDB: 113.4,
            calibratedAt: Date(timeIntervalSince1970: 1_000)
        )
        settings.calibrations[key] = record
        settings.spectrogram.displayMode = .spectrogram
        do {
            let data = try PropertyListEncoder().encode(settings)
            guard var root = try PropertyListSerialization.propertyList(
                from: data,
                format: nil
            ) as? [String: Any],
                  var spectrogram = root["spectrogram"] as? [String: Any] else {
                failures.append("Settings test could not inspect the encoded property list")
                return
            }
            spectrogram["displayMode"] = "valueFromNewerVersion"
            root["spectrogram"] = spectrogram
            let corrupted = try PropertyListSerialization.data(
                fromPropertyList: root,
                format: .binary,
                options: 0
            )
            let decoded = try PropertyListDecoder().decode(PersistedSettings.self, from: corrupted)
            if decoded.calibrations[key] != record {
                failures.append("Unreadable analysis setting discarded stored calibrations")
            }
            if decoded.spectrogram != SpectrogramSettings() {
                failures.append("Unreadable analysis settings were not reset to defaults")
            }
        } catch {
            failures.append("Settings with one unreadable field failed to decode: \(error)")
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
        let defaultSpectrogram = SpectrogramSettings()
        if defaultSpectrogram.upperLevelDB != 100
            || defaultSpectrogram.dynamicRangeDB != 50
            || defaultSpectrogram.transferFunctionRangeDB != 12
            || defaultSpectrogram.palette != .current
            || defaultSpectrogram.displayMode != .none {
            failures.append("Analysis defaults were not 100/50 dB and TF ±12 dB")
        }
        if defaultSpectrogram.transferFunctionSmoothing != .oneSixth
            || TransferFunctionSmoothing.allCases.map(\.bandsPerOctave) != [48, 24, 12, 6, 3, 1] {
            failures.append("Transfer function smoothing defaults or options changed")
        }
        if AnalysisDisplayMode.spectrogram.next != .transferFunction
            || AnalysisDisplayMode.transferFunction.next != .combined
            || AnalysisDisplayMode.combined.next != .meterBridge
            || AnalysisDisplayMode.meterBridge.next != .wireless
            || AnalysisDisplayMode.wireless.next != .none
            || AnalysisDisplayMode.none.next != .spectrogram {
            failures.append("Analysis display mode cycle order changed")
        }
        if !AnalysisDisplayMode.spectrogram.showsSpectrogram
            || AnalysisDisplayMode.spectrogram.showsTransferFunction
            || AnalysisDisplayMode.transferFunction.showsSpectrogram
            || !AnalysisDisplayMode.transferFunction.showsTransferFunction
            || !AnalysisDisplayMode.combined.showsSpectrogram
            || !AnalysisDisplayMode.combined.showsTransferFunction
            || AnalysisDisplayMode.none.showsSpectrogram
            || AnalysisDisplayMode.none.showsTransferFunction {
            failures.append("Analysis display mode visibility changed")
        }
        let boundedSpectrogram = SpectrogramSettings(
            upperLevelDB: 1_000,
            dynamicRangeDB: -1,
            transferFunctionRangeDB: 1_000
        )
        if boundedSpectrogram.upperLevelDB != SpectrogramSettings.allowedUpperLevelDB.upperBound
            || boundedSpectrogram.dynamicRangeDB
                != SpectrogramSettings.allowedDynamicRangeDB.lowerBound
            || boundedSpectrogram.transferFunctionRangeDB
                != SpectrogramSettings.allowedTransferFunctionRangeDB.upperBound
            || SpectrogramSettings.validatedTransferFunctionRange(-1)
                != SpectrogramSettings.allowedTransferFunctionRangeDB.lowerBound {
            failures.append("Analysis level settings were not bounded")
        }

        let key = CalibrationKey(deviceUID: "test-device", channel: 2)
        var settings = PersistedSettings()
        settings.input = InputSelection(deviceUID: key.deviceUID, channel: key.channel)
        settings.calibrations[key] = CalibrationRecord(
            offsetDB: 112.3,
            calibratedAt: Date(timeIntervalSince1970: 100)
        )
        settings.spectrogram = SpectrogramSettings(
            displayMode: .combined,
            frequencyRange: .focused,
            historyDuration: .long,
            intensity: .high,
            palette: .rgb,
            upperLevelDB: 108,
            dynamicRangeDB: 64,
            transferFunctionRangeDB: 24,
            transferFunctionSmoothing: .oneTwentyFourth,
            referenceChannel: 1
        )
        do {
            let encoded = try PropertyListEncoder().encode(settings)
            let decoded = try PropertyListDecoder().decode(PersistedSettings.self, from: encoded)
            if decoded != settings { failures.append("Settings persistence did not round-trip") }

            guard var booleanLegacyObject = try PropertyListSerialization.propertyList(
                from: encoded,
                format: nil
            ) as? [String: Any],
            var booleanLegacySpectrogram = booleanLegacyObject["spectrogram"]
                as? [String: Any] else {
                failures.append("Boolean display mode compatibility fixture could not be created")
                return
            }
            booleanLegacySpectrogram.removeValue(forKey: "displayMode")
            booleanLegacyObject["spectrogram"] = booleanLegacySpectrogram
            let booleanLegacyData = try PropertyListSerialization.data(
                fromPropertyList: booleanLegacyObject,
                format: .binary,
                options: 0
            )
            let booleanLegacyDecoded = try PropertyListDecoder().decode(
                PersistedSettings.self,
                from: booleanLegacyData
            )
            if booleanLegacyDecoded.spectrogram.displayMode != .transferFunction {
                failures.append("Legacy analysis visibility booleans were not migrated")
            }

            guard var legacyObject = try PropertyListSerialization.propertyList(
                from: encoded,
                format: nil
            ) as? [String: Any] else {
                failures.append("Settings compatibility fixture could not be created")
                return
            }
            legacyObject.removeValue(forKey: "spectrogram")
            let legacyData = try PropertyListSerialization.data(
                fromPropertyList: legacyObject,
                format: .binary,
                options: 0
            )
            let legacyDecoded = try PropertyListDecoder().decode(
                PersistedSettings.self,
                from: legacyData
            )
            if legacyDecoded.spectrogram != SpectrogramSettings() {
                failures.append("Legacy settings did not receive default spectrogram settings")
            }

            guard var nestedLegacyObject = try PropertyListSerialization.propertyList(
                from: encoded,
                format: nil
            ) as? [String: Any],
            var nestedSpectrogram = nestedLegacyObject["spectrogram"] as? [String: Any] else {
                failures.append("Nested spectrogram compatibility fixture could not be created")
                return
            }
            nestedSpectrogram.removeValue(forKey: "upperLevelDB")
            nestedSpectrogram.removeValue(forKey: "dynamicRangeDB")
            nestedSpectrogram.removeValue(forKey: "transferFunctionRangeDB")
            nestedSpectrogram.removeValue(forKey: "palette")
            nestedSpectrogram.removeValue(forKey: "displayMode")
            nestedSpectrogram.removeValue(forKey: "isTransferFunctionEnabled")
            nestedSpectrogram.removeValue(forKey: "referenceChannel")
            nestedSpectrogram.removeValue(forKey: "transferFunctionSmoothing")
            nestedLegacyObject["spectrogram"] = nestedSpectrogram
            let nestedLegacyData = try PropertyListSerialization.data(
                fromPropertyList: nestedLegacyObject,
                format: .binary,
                options: 0
            )
            let nestedLegacyDecoded = try PropertyListDecoder().decode(
                PersistedSettings.self,
                from: nestedLegacyData
            )
            if nestedLegacyDecoded.spectrogram.upperLevelDB != 100
                || nestedLegacyDecoded.spectrogram.dynamicRangeDB != 50
                || nestedLegacyDecoded.spectrogram.transferFunctionRangeDB != 12
                || nestedLegacyDecoded.spectrogram.palette != .current
                || nestedLegacyDecoded.spectrogram.displayMode != .spectrogram
                || nestedLegacyDecoded.spectrogram.transferFunctionSmoothing != .default
                || nestedLegacyDecoded.spectrogram.referenceChannel != nil {
                failures.append("Legacy analysis settings did not receive current level defaults")
            }
            if nestedLegacyDecoded.spectrogram.frequencyRange != .focused
                || nestedLegacyDecoded.spectrogram.historyDuration != .long
                || nestedLegacyDecoded.spectrogram.intensity != .high {
                failures.append("Legacy spectrogram settings lost their existing fields")
            }

            guard var unknownSmoothingObject = try PropertyListSerialization.propertyList(
                from: encoded,
                format: nil
            ) as? [String: Any],
            var unknownSmoothingSpectrogram = unknownSmoothingObject["spectrogram"]
                as? [String: Any] else {
                failures.append("Unknown smoothing fixture could not be created")
                return
            }
            unknownSmoothingSpectrogram["transferFunctionSmoothing"] = 7
            unknownSmoothingObject["spectrogram"] = unknownSmoothingSpectrogram
            let unknownSmoothingDecoded = try PropertyListDecoder().decode(
                PersistedSettings.self,
                from: PropertyListSerialization.data(
                    fromPropertyList: unknownSmoothingObject,
                    format: .binary,
                    options: 0
                )
            )
            var expectedUnknownSmoothing = settings.spectrogram
            expectedUnknownSmoothing.transferFunctionSmoothing = .default
            if unknownSmoothingDecoded.spectrogram != expectedUnknownSmoothing {
                failures.append("Unknown transfer function smoothing reset other analysis settings")
            }
        } catch {
            failures.append("Settings persistence failed: \(error.localizedDescription)")
        }
    }

    private static func testSpectrogramAnalyzer(_ failures: inout [String]) {
        let sampleRate = 48_000.0
        let frameCount = SpectrogramAnalyzer.frameCount(forSampleRate: sampleRate)
        if frameCount != 8_192 {
            failures.append("Spectrogram FFT size was not fixed at 8192 samples")
        }

        guard let focusedScale = SpectrogramFrequencyScale(
            sampleRate: sampleRate,
            frameCount: frameCount,
            range: .focused
        ) else {
            failures.append("Spectrogram did not produce a valid focused frequency scale")
            return
        }
        let transferFunctionFrequencies = TransferFunctionDSP.gridFrequencies(
            for: focusedScale
        )
        let transferFunctionStep = pow(2, 1.0 / 48)
        if transferFunctionFrequencies.count < 2
            || transferFunctionFrequencies.dropFirst().enumerated().contains(where: {
                index, frequency in
                abs(frequency / transferFunctionFrequencies[index] - transferFunctionStep)
                    > 1e-12
            }) {
            failures.append("Transfer-function bands were not spaced at 1/48 octave")
        }
        let expectedStep = pow(2, 1.0 / 24)
        let binWidth = sampleRate / Double(frameCount)
        let centerFrequencies = SpectrogramAnalyzer.spectrogramCenterFrequencies(
            for: focusedScale,
            binWidth: binWidth
        )
        let transition = SpectrogramAnalyzer.resolvedBandTransitionFrequency(
            binWidth: binWidth
        )
        let nativeFrequencies = centerFrequencies.filter { $0 < transition }
        let smoothedFrequencies = centerFrequencies.filter { $0 >= transition }
        if nativeFrequencies.isEmpty
            || nativeFrequencies.contains(where: {
                abs($0 / binWidth - ($0 / binWidth).rounded()) > 1e-12
            }) {
            failures.append("Spectrogram did not use native FFT bins below its resolution")
        }
        if smoothedFrequencies.count < 2
            || smoothedFrequencies.dropFirst().enumerated().contains(where: {
                index, frequency in
                abs(frequency / smoothedFrequencies[index] - expectedStep) > 1e-12
            }) {
            failures.append("Spectrogram did not retain 1/24-octave bands above its resolution")
        }
        if centerFrequencies.last.map({ $0 > focusedScale.upperFrequency }) ?? true {
            failures.append("Spectrogram frequencies exceeded their displayed frequency scale")
        }

        let toneBin = 171
        let frequency = Double(toneBin) * sampleRate / Double(frameCount)
        let samples = (0..<frameCount).map { index in
            Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
        let spectrum = SpectrogramAnalyzer.spectrum(
            samples: samples,
            sampleRate: sampleRate,
            range: .focused
        )
        guard spectrum.count == centerFrequencies.count,
              let peakBand = spectrum.indices.max(by: { spectrum[$0] < spectrum[$1] }) else {
            failures.append("Spectrogram did not produce its expected frequency bands")
            return
        }
        let expectedBand = centerFrequencies.indices.min {
            abs(centerFrequencies[$0] - frequency) < abs(centerFrequencies[$1] - frequency)
        } ?? 0
        if abs(peakBand - expectedBand) > 1 {
            failures.append("Spectrogram placed a 1 kHz tone in the wrong frequency band")
        }
        if abs(spectrum[peakBand]) > 0.5 {
            failures.append("Spectrogram Hann normalization did not place a full-scale tone near 0 dBFS")
        }

        func peakLevel(amplitude: Double) -> Double {
            let signal = (0..<frameCount).map { index in
                Float(amplitude * sin(2 * Double.pi * frequency * Double(index) / sampleRate))
            }
            let values = SpectrogramAnalyzer.spectrum(
                samples: signal,
                sampleRate: sampleRate,
                range: .focused
            )
            return Double(values.max() ?? -.infinity)
        }
        let levelAtMinus20 = peakLevel(amplitude: 0.1)
        let levelAtMinus40 = peakLevel(amplitude: 0.01)
        if abs(levelAtMinus20 + 20) > 0.5
            || abs(levelAtMinus40 + 40) > 0.5
            || abs(levelAtMinus20 - levelAtMinus40 - 20) > 0.2 {
            failures.append("Spectrogram did not preserve unclipped dBFS levels")
        }

        let calibrationOffsetDB = 97.0102999566
        let calibratedScale = SpectrogramLevelScale(
            upperLevelDB: 100,
            dynamicRangeDB: 50,
            calibrationOffsetDB: calibrationOffsetDB
        )
        let upperDBFS = 100
            - calibrationOffsetDB
            - SpectrogramLevelScale.fullScaleSinePeakToRMSDB
        let lowerDBFS = upperDBFS - calibratedScale.dynamicRangeDB
        if abs(calibratedScale.normalizedValue(for: upperDBFS) - 1) > 1e-12
            || abs(calibratedScale.normalizedValue(for: lowerDBFS)) > 1e-12 {
            failures.append("Spectrogram level mapping did not preserve its configured endpoints")
        }
        let fullScaleLevel = calibratedScale.displayedLevelDB(
            for: Double(spectrum[peakBand])
        )
        if abs(fullScaleLevel - 94) > 0.5 {
            failures.append("Spectrogram calibration did not map a 94 dB 1 kHz tone correctly")
        }
        let normalizedAtFullScale = calibratedScale.normalizedValue(
            for: Double(spectrum[peakBand])
        )
        let normalizedAtMinus20 = calibratedScale.normalizedValue(for: levelAtMinus20)
        if abs(normalizedAtFullScale - normalizedAtMinus20 - 20 / 50) > 0.02 {
            failures.append("Spectrogram level mapping did not preserve signal attenuation")
        }

        let relativeScale = SpectrogramLevelScale(
            upperLevelDB: 140,
            dynamicRangeDB: 50,
            calibrationOffsetDB: nil
        )
        if relativeScale.displayedUpperLevelDB != 0
            || abs(relativeScale.normalizedValue(for: 0) - 1) > 1e-12
            || abs(relativeScale.normalizedValue(for: -50)) > 1e-12 {
            failures.append("Uncalibrated spectrogram did not use its fixed 0 dBFS ceiling")
        }
        if abs(relativeScale.normalizedValue(for: -20) - 0.6) > 1e-12
            || abs(relativeScale.normalizedValue(for: -40) - 0.2) > 1e-12 {
            failures.append("Uncalibrated spectrogram did not preserve relative attenuation")
        }

        let silence = SpectrogramAnalyzer.spectrum(
            samples: Array(repeating: 0, count: frameCount),
            sampleRate: sampleRate,
            range: .full
        )
        if silence.contains(where: { $0 > -199.9 }) {
            failures.append("Spectrogram did not retain digital silence below the display range")
        }

        for supportedRate in [32_000.0, 48_000.0, 96_000.0, 192_000.0] {
            let count = SpectrogramAnalyzer.frameCount(forSampleRate: supportedRate)
            if count != 8_192 {
                failures.append("Spectrogram varied its FFT size with the sample rate")
            }

            var spectrallyWhiteImpulse = [Float](repeating: 0, count: count)
            spectrallyWhiteImpulse[count / 2] = 1
            let whiteSpectrum = SpectrogramAnalyzer.spectrum(
                samples: spectrallyWhiteImpulse,
                sampleRate: supportedRate,
                range: .full
            )
            guard let whiteScale = SpectrogramFrequencyScale(
                sampleRate: supportedRate,
                frameCount: count,
                range: .full
            ) else {
                failures.append("Spectrogram could not measure a spectrally white test signal")
                continue
            }
            let binWidth = supportedRate / Double(count)
            let transition = SpectrogramAnalyzer.resolvedBandTransitionFrequency(
                binWidth: binWidth
            )
            let whiteFrequencies = SpectrogramAnalyzer.spectrogramCenterFrequencies(
                for: whiteScale,
                binWidth: binWidth
            )
            if whiteFrequencies.count != whiteSpectrum.count {
                failures.append("Spectrogram values did not match its hybrid frequency grid")
                continue
            }
            let whiteBandShape = zip(whiteFrequencies, whiteSpectrum).compactMap {
                frequency, level in
                frequency <= min(8_000, whiteScale.upperFrequency / 2)
                    ? Double(level) - 10 * log10(frequency)
                    : nil
            }
            if let minimumWhiteShape = whiteBandShape.min(),
               let maximumWhiteShape = whiteBandShape.max(),
               maximumWhiteShape - minimumWhiteShape > 0.2 {
                failures.append(
                    String(
                        format: "Spectrogram white-noise band-power shape varied by %.2f dB at %.0f Hz sample rate",
                        maximumWhiteShape - minimumWhiteShape,
                        supportedRate
                    )
                )
            }

            let lastBin = Int(ceil(whiteScale.upperFrequency / binWidth))
            var pinkBinPower = [Double](repeating: 0, count: lastBin + 1)
            if lastBin >= 1 {
                for bin in 1...lastBin {
                    pinkBinPower[bin] = 1 / (Double(bin) * binWidth)
                }
            }
            let pinkSpectrum = SpectrogramAnalyzer.spectrogramLevels(
                binPower: pinkBinPower,
                binWidth: binWidth,
                frequencyScale: whiteScale
            )
            let nativePinkLevels = zip(whiteFrequencies, pinkSpectrum).compactMap {
                frequency, level in
                frequency < transition
                    ? level
                    : nil
            }
            if let minimum = nativePinkLevels.min(),
               let maximum = nativePinkLevels.max(),
               maximum - minimum > 0.01 {
                failures.append(
                    String(
                        format: "Spectrogram normalized native pink-noise bins varied by %.2f dB at %.0f Hz sample rate",
                        maximum - minimum,
                        supportedRate
                    )
                )
            }
            let smoothedPinkLevels = zip(whiteFrequencies, pinkSpectrum).compactMap {
                frequency, level in
                frequency >= transition
                    && frequency <= min(8_000, whiteScale.upperFrequency / 2)
                    ? level
                    : nil
            }
            if let minimum = smoothedPinkLevels.min(),
               let maximum = smoothedPinkLevels.max(),
               maximum - minimum > 1.0 {
                failures.append(
                    String(
                        format: "Spectrogram resolved pink-noise bands varied by %.2f dB at %.0f Hz sample rate",
                        maximum - minimum,
                        supportedRate
                    )
                )
            }
            if let lastNativeIndex = whiteFrequencies.lastIndex(where: { $0 < transition }),
               let firstSmoothedIndex = whiteFrequencies.firstIndex(where: { $0 >= transition }) {
                let crossoverStep = Double(
                    pinkSpectrum[firstSmoothedIndex] - pinkSpectrum[lastNativeIndex]
                )
                if abs(crossoverStep) > 0.5 {
                    failures.append(
                        String(
                            format: "Spectrogram hybrid crossover step was %.2f dB at %.0f Hz sample rate",
                            crossoverStep,
                            supportedRate
                        )
                    )
                }
            }

            func toneSpectrumPeak(frequency: Double, amplitude: Double) -> Double {
                let tone = (0..<count).map { index in
                    Float(
                        amplitude * sin(
                            2 * Double.pi * frequency * Double(index) / supportedRate
                        )
                    )
                }
                return Double(
                    SpectrogramAnalyzer.spectrum(
                        samples: tone,
                        sampleRate: supportedRate,
                        range: .full
                    ).max() ?? -.infinity
                )
            }
            let resolvedToneBin = Int(
                (max(8_000, transition * 2) * Double(count) / supportedRate).rounded()
            )
            let resolvedToneFrequency = Double(resolvedToneBin) * binWidth
            let fullScaleTonePeak = toneSpectrumPeak(
                frequency: resolvedToneFrequency,
                amplitude: 1
            )
            let attenuatedTonePeak = toneSpectrumPeak(
                frequency: resolvedToneFrequency,
                amplitude: 0.1
            )
            // A tone on a 1/24-octave boundary can split evenly between two
            // adjacent bands, so its strongest band may be as low as -3 dB.
            if fullScaleTonePeak < -3.2
                || fullScaleTonePeak > 0.5
                || abs(fullScaleTonePeak - attenuatedTonePeak - 20) > 0.2 {
                failures.append(
                    String(
                        format: "Spectrogram resolved tone levels were %.2f/%.2f dB at %.0f Hz sample rate",
                        fullScaleTonePeak,
                        attenuatedTonePeak,
                        supportedRate
                    )
                )
            }

            let lowFrequencyBin = max(
                1,
                Int((50 * Double(count) / supportedRate).rounded())
            )
            let lowFrequency = Double(lowFrequencyBin) * supportedRate / Double(count)
            let fullScaleLowTonePeak = toneSpectrumPeak(
                frequency: lowFrequency,
                amplitude: 1
            )
            let attenuatedLowTonePeak = toneSpectrumPeak(
                frequency: lowFrequency,
                amplitude: 0.1
            )
            let expectedRawHannPeakDB = 10 * log10(2.0 / 3.0)
            let lowNominalBounds = SpectrogramAnalyzer.nominalSmoothingFrequencyBounds(
                centerFrequency: lowFrequency
            )
            let expectedNormalizedLowToneDB = expectedRawHannPeakDB + 10 * log10(
                (lowNominalBounds.upper - lowNominalBounds.lower) / binWidth
            )
            if abs(fullScaleLowTonePeak - expectedNormalizedLowToneDB) > 0.2
                || abs(fullScaleLowTonePeak - attenuatedLowTonePeak - 20) > 0.2 {
                failures.append(
                    String(
                        format: "Spectrogram normalized native-bin tone levels were %.2f/%.2f dB, expected %.2f dB at %.0f Hz sample rate",
                        fullScaleLowTonePeak,
                        attenuatedLowTonePeak,
                        expectedNormalizedLowToneDB,
                        supportedRate
                    )
                )
            }
        }

        guard let fullScale = SpectrogramFrequencyScale(
            sampleRate: 32_000,
            frameCount: 8_192,
            range: .full
        ),
        abs(fullScale.lowerFrequency - 20) < 1e-12,
        abs(fullScale.upperFrequency - 16_000) < 1e-12,
        let oneKilohertzPosition = fullScale.position(for: 1_000),
        abs(oneKilohertzPosition - log(50) / log(800)) < 1e-12 else {
            failures.append("Spectrogram frequency scale did not match its logarithmic FFT bounds")
            return
        }
        if fullScale.position(for: 20_000) != nil {
            failures.append("Spectrogram frequency scale exceeded the input Nyquist frequency")
        }
        let gradientStops = SpectrogramGradientLayout.stopPositions(
            frequencies: [20, 200, 2_000, 16_000],
            valueCount: 4,
            scale: fullScale
        )
        guard gradientStops.first?.location == 0,
              gradientStops.last?.location == 1,
              let twoHundredStop = gradientStops.first(where: { $0.sourceIndex == 1 }),
              abs(twoHundredStop.location - log(10) / log(800)) < 1e-12 else {
            failures.append("Spectrogram gradient did not use its logarithmic frequency axis")
            return
        }
        let interiorGradientStops = SpectrogramGradientLayout.stopPositions(
            frequencies: [40, 8_000],
            valueCount: 2,
            scale: fullScale
        )
        if interiorGradientStops.first
            != SpectrogramGradientStopPosition(sourceIndex: 0, location: 0)
            || interiorGradientStops.last
                != SpectrogramGradientStopPosition(sourceIndex: 1, location: 1) {
            failures.append("Spectrogram gradient did not cover its frequency-axis endpoints")
        }
        guard let highRateScale = SpectrogramFrequencyScale(
            sampleRate: 192_000,
            frameCount: 8_192,
            range: .full
        ), abs(highRateScale.lowerFrequency - 23.4375) < 1e-12 else {
            failures.append("Spectrogram frequency scale mislabeled its 192 kHz FFT lower bound")
            return
        }
    }

    private static func testSpectrogramTimeline(_ failures: inout [String]) {
        let interval = Double(SpectrogramAnalyzer.fftSize) / 32_000.0
        let columns = (0...100).map { index in
            SpectrogramColumn(
                capturedAtUptime: Double(index) * interval,
                coveredDuration: interval,
                levelsDBFS: [0]
            )
        }
        let reference = columns.last?.capturedAtUptime ?? 0
        let duration = 10.0
        let expired = SpectrogramTimeline.expiredPrefixCount(
            in: columns,
            referenceUptime: reference,
            historyDuration: duration
        )
        let retained = Array(columns.dropFirst(expired))
        let retainedSpan = retained.first.map { reference - $0.capturedAtUptime }
        if retainedSpan.map({ $0 > duration + interval || $0 < duration }) ?? true {
            failures.append("Spectrogram history exceeded its elapsed-time duration")
        }
        let oldest = SpectrogramTimeline.timeFraction(
            for: reference - duration,
            referenceUptime: reference,
            historyDuration: duration
        )
        let newest = SpectrogramTimeline.timeFraction(
            for: reference,
            referenceUptime: reference,
            historyDuration: duration
        )
        if abs(oldest) > 1e-12 || abs(newest - 1) > 1e-12 {
            failures.append("Spectrogram timeline did not span its configured duration")
        }

        let beforeGap = SpectrogramColumn(
            capturedAtUptime: 2,
            coveredDuration: interval,
            levelsDBFS: [0]
        )
        let endBeforeGap = SpectrogramTimeline.visibleEndUptime(
            for: beforeGap,
            nextColumnUptime: 8,
            referenceUptime: 10
        )
        if abs(endBeforeGap - (2 + interval)) > 1e-12 {
            failures.append("Spectrogram stretched old data across an audio gap")
        }
        let finalColumn = SpectrogramColumn(
            capturedAtUptime: 8,
            coveredDuration: interval,
            levelsDBFS: [0]
        )
        let finalEnd = SpectrogramTimeline.visibleEndUptime(
            for: finalColumn,
            nextColumnUptime: nil,
            referenceUptime: 10
        )
        if abs(finalEnd - (8 + interval)) > 1e-12 {
            failures.append("Spectrogram stretched its final column across an audio gap")
        }
        let freshColumn = SpectrogramColumn(
            capturedAtUptime: reference - interval,
            coveredDuration: interval,
            levelsDBFS: [0]
        )
        let freshEnd = SpectrogramTimeline.visibleEndUptime(
            for: freshColumn,
            nextColumnUptime: nil,
            referenceUptime: reference
        )
        if abs(freshEnd - reference) > 1e-12 {
            failures.append("Spectrogram placed fresh audio coverage in the future")
        }

        let rasterColumns = [
            SpectrogramColumn(
                capturedAtUptime: 0,
                coveredDuration: 2.25,
                levelsDBFS: [-30, -20]
            ),
            SpectrogramColumn(
                capturedAtUptime: 2.25,
                coveredDuration: 1,
                levelsDBFS: [-10, -25]
            ),
            SpectrogramColumn(
                capturedAtUptime: 7,
                coveredDuration: 1,
                levelsDBFS: [-15, -5]
            )
        ]
        let rasterRows = SpectrogramRasterizer.rows(
            for: rasterColumns,
            referenceUptime: 10,
            historyDuration: 10,
            pixelHeight: 10
        )
        if rasterRows.map(\.pixelIndex) != [0, 1, 2, 3, 7] {
            failures.append("Spectrogram rasterizer did not preserve pixel coverage and audio gaps")
        }
        if rasterRows.first(where: { $0.pixelIndex == 2 })?.levelsDBFS != [-10, -20] {
            failures.append("Spectrogram rasterizer did not merge overlapping frames by peak level")
        }
        let rasterRuns = SpectrogramRasterizer.runs(
            for: rasterColumns,
            referenceUptime: 10,
            historyDuration: 10,
            pixelHeight: 10
        )
        if rasterRuns.map(\.firstPixelIndex) != [0, 2, 3, 7]
            || rasterRuns.map(\.pixelCount) != [2, 1, 1, 1]
            || rasterRuns.first?.levelsDBFS != [-30, -20] {
            failures.append("Spectrogram rasterizer did not coalesce identical rows around gaps")
        }
    }

    private static func testTransferFunctionAnalyzer(_ failures: inout [String]) {
        let automaticGainRange = TransferFunctionDSP.automaticDisplayRange([
            TransferFunctionPoint(frequency: 499, magnitudeDB: -100),
            TransferFunctionPoint(frequency: 500, magnitudeDB: -6),
            TransferFunctionPoint(frequency: 1_000, magnitudeDB: .nan),
            TransferFunctionPoint(frequency: 4_000, magnitudeDB: 6),
            TransferFunctionPoint(frequency: 4_001, magnitudeDB: 100)
        ])
        if abs(automaticGainRange.lower + 9) > 1e-12
            || abs(automaticGainRange.upper - 9) > 1e-12 {
            failures.append("Transfer function AutoGain did not use only 500-4000 Hz values")
        }
        let emptyAutomaticGainRange = TransferFunctionDSP.automaticDisplayRange([
            TransferFunctionPoint(frequency: 100, magnitudeDB: -100),
            TransferFunctionPoint(frequency: 1_000, magnitudeDB: .infinity),
            TransferFunctionPoint(frequency: 8_000, magnitudeDB: 100)
        ])
        if emptyAutomaticGainRange.lower != -12 || emptyAutomaticGainRange.upper != 12 {
            failures.append("Transfer function AutoGain did not use its neutral fallback")
        }
        let automaticGainStep = TransferFunctionDSP.smoothedAutomaticDisplayRange(
            current: (14, 26),
            previous: (-6, 6),
            elapsedTime: TransferFunctionDSP.automaticGainSmoothingTimeConstant
        )
        let expectedStepCenter = 20 * (1 - exp(-1.0))
        let automaticGainStepCenter = automaticGainStep.lower / 2
            + automaticGainStep.upper / 2
        if abs(automaticGainStepCenter - expectedStepCenter) > 1e-12
            || abs(automaticGainStep.upper - automaticGainStep.lower - 12) > 1e-12 {
            failures.append("Transfer function AutoGain did not smooth a timed level step")
        }
        let followedAutomaticGainStep = TransferFunctionDSP.smoothedAutomaticDisplayRange(
            current: (14, 26),
            previous: automaticGainStep,
            elapsedTime: TransferFunctionDSP.automaticGainSmoothingTimeConstant
        )
        let followedAutomaticGainCenter = followedAutomaticGainStep.lower / 2
            + followedAutomaticGainStep.upper / 2
        if followedAutomaticGainCenter <= automaticGainStepCenter
            || followedAutomaticGainCenter >= 20 {
            failures.append("Transfer function AutoGain smoothing did not follow a sustained step")
        }
        var subdividedAutomaticGainRange = (lower: -6.0, upper: 6.0)
        for _ in 0..<3 {
            subdividedAutomaticGainRange = TransferFunctionDSP.smoothedAutomaticDisplayRange(
                current: (14, 26),
                previous: subdividedAutomaticGainRange,
                elapsedTime: TransferFunctionDSP.automaticGainSmoothingTimeConstant / 3
            )
        }
        let subdividedAutomaticGainCenter = subdividedAutomaticGainRange.lower / 2
            + subdividedAutomaticGainRange.upper / 2
        if abs(subdividedAutomaticGainCenter - automaticGainStepCenter) > 1e-12 {
            failures.append("Transfer function AutoGain smoothing depended on update rate")
        }
        let unsmoothedAutomaticGainRange = TransferFunctionDSP.smoothedAutomaticDisplayRange(
            current: (14, 26),
            previous: nil,
            elapsedTime: nil
        )
        let invalidTimeAutomaticGainRange = TransferFunctionDSP.smoothedAutomaticDisplayRange(
            current: (14, 26),
            previous: (-6, 6),
            elapsedTime: .nan
        )
        let reversedTimeAutomaticGainRange = TransferFunctionDSP.smoothedAutomaticDisplayRange(
            current: (14, 26),
            previous: (-6, 6),
            elapsedTime: -1
        )
        let invalidLevelAutomaticGainRange = TransferFunctionDSP.smoothedAutomaticDisplayRange(
            current: (.nan, 26),
            previous: (-6, 6),
            elapsedTime: 1
        )
        if unsmoothedAutomaticGainRange.lower != 14
            || unsmoothedAutomaticGainRange.upper != 26
            || invalidTimeAutomaticGainRange.lower != 14
            || invalidTimeAutomaticGainRange.upper != 26
            || reversedTimeAutomaticGainRange.lower != 14
            || reversedTimeAutomaticGainRange.upper != 26
            || invalidLevelAutomaticGainRange.lower != -12
            || invalidLevelAutomaticGainRange.upper != 12 {
            failures.append("Transfer function AutoGain smoothing did not reset safely")
        }
        guard let averagingScale = SpectrogramFrequencyScale(
            sampleRate: 48_000,
            frameCount: SpectrogramAnalyzer.fftSize,
            range: .focused
        ), let alternateAveragingScale = SpectrogramFrequencyScale(
            sampleRate: 48_000,
            frameCount: SpectrogramAnalyzer.fftSize,
            range: .full
        ) else {
            failures.append("Transfer function averaging scales were invalid")
            return
        }
        var curveAverager = TransferFunctionAverager()
        let firstAverage = curveAverager.average(
            points: [
                TransferFunctionPoint(frequency: 500, magnitudeDB: 0),
                TransferFunctionPoint(frequency: 1_000, magnitudeDB: 10)
            ],
            frequencyScale: averagingScale,
            capturedAtUptime: 0,
            blockDuration: 1
        )
        let missingFrequencyAverage = curveAverager.average(
            points: [
                TransferFunctionPoint(frequency: 500, magnitudeDB: 10)
            ],
            frequencyScale: averagingScale,
            capturedAtUptime: 1,
            blockDuration: 1
        )
        let reappearedFrequencyAverage = curveAverager.average(
            points: [
                TransferFunctionPoint(frequency: 500, magnitudeDB: 20),
                TransferFunctionPoint(frequency: 1_000, magnitudeDB: 40)
            ],
            frequencyScale: averagingScale,
            capturedAtUptime: 2,
            blockDuration: 1
        )
        if firstAverage.map(\.magnitudeDB) != [0, 10]
            || missingFrequencyAverage.map(\.magnitudeDB) != [5, 10]
            || reappearedFrequencyAverage.map(\.magnitudeDB) != [10, 25] {
            failures.append("Transfer function did not retain and average intermittently excited bands")
        }
        let averagedAutomaticGainRange = TransferFunctionDSP.automaticDisplayRange(
            reappearedFrequencyAverage
        )
        if averagedAutomaticGainRange.lower != 7
            || averagedAutomaticGainRange.upper != 28 {
            failures.append("Transfer function AutoGain did not use the averaged curve")
        }
        for start in [3.0, 4.0] {
            _ = curveAverager.average(
                points: [
                    TransferFunctionPoint(frequency: 500, magnitudeDB: 30),
                    TransferFunctionPoint(frequency: 1_000, magnitudeDB: 40)
                ],
                frequencyScale: averagingScale,
                capturedAtUptime: start,
                blockDuration: 1
            )
        }
        let expiredFrequencyAverage = curveAverager.average(
            points: [
                TransferFunctionPoint(frequency: 500, magnitudeDB: 30),
                TransferFunctionPoint(frequency: 1_000, magnitudeDB: 40)
            ],
            frequencyScale: averagingScale,
            capturedAtUptime: 5,
            blockDuration: 1
        )
        if expiredFrequencyAverage.map(\.magnitudeDB) != [24, 40] {
            failures.append("Transfer function average did not expire observations after five seconds")
        }

        curveAverager.reset()
        _ = curveAverager.average(
            points: [TransferFunctionPoint(frequency: 500, magnitudeDB: 0)],
            frequencyScale: averagingScale,
            capturedAtUptime: 0,
            blockDuration: 4
        )
        let durationWeightedAverage = curveAverager.average(
            points: [TransferFunctionPoint(frequency: 500, magnitudeDB: 12)],
            frequencyScale: averagingScale,
            capturedAtUptime: 4,
            blockDuration: 4
        )
        if abs((durationWeightedAverage.first?.magnitudeDB ?? .infinity) - 9.6) > 1e-12 {
            failures.append("Transfer function average did not weight a partial window overlap")
        }
        var subdividedCurveAverager = TransferFunctionAverager()
        for start in 0..<7 {
            _ = subdividedCurveAverager.average(
                points: [TransferFunctionPoint(
                    frequency: 500,
                    magnitudeDB: start < 4 ? 0 : 12
                )],
                frequencyScale: averagingScale,
                capturedAtUptime: Double(start),
                blockDuration: 1
            )
        }
        let subdividedDurationAverage = subdividedCurveAverager.average(
            points: [TransferFunctionPoint(frequency: 500, magnitudeDB: 12)],
            frequencyScale: averagingScale,
            capturedAtUptime: 7,
            blockDuration: 1
        )
        if abs(
            (subdividedDurationAverage.first?.magnitudeDB ?? .infinity)
                - (durationWeightedAverage.first?.magnitudeDB ?? -.infinity)
        ) > 1e-12 {
            failures.append("Transfer function average depended on block subdivision")
        }

        var gapCurveAverager = TransferFunctionAverager()
        _ = gapCurveAverager.average(
            points: [TransferFunctionPoint(frequency: 500, magnitudeDB: 0)],
            frequencyScale: averagingScale,
            capturedAtUptime: 0,
            blockDuration: 1
        )
        let averageAfterGap = gapCurveAverager.average(
            points: [TransferFunctionPoint(frequency: 500, magnitudeDB: 10)],
            frequencyScale: averagingScale,
            capturedAtUptime: 2,
            blockDuration: 1
        )
        if averageAfterGap.first?.magnitudeDB != 5 {
            failures.append("Transfer function average discarded valid history across a short gap")
        }

        var stepCurveAverager = TransferFunctionAverager()
        _ = stepCurveAverager.average(
            points: [TransferFunctionPoint(frequency: 500, magnitudeDB: 0)],
            frequencyScale: averagingScale,
            capturedAtUptime: 0,
            blockDuration: 1
        )
        for start in [1.0, 2.0, 3.0, 4.0] {
            _ = stepCurveAverager.average(
                points: [TransferFunctionPoint(frequency: 500, magnitudeDB: 10)],
                frequencyScale: averagingScale,
                capturedAtUptime: start,
                blockDuration: 1
            )
        }
        let settledStepAverage = stepCurveAverager.average(
            points: [TransferFunctionPoint(frequency: 500, magnitudeDB: 10)],
            frequencyScale: averagingScale,
            capturedAtUptime: 5,
            blockDuration: 1
        )
        let constantStepAverage = stepCurveAverager.average(
            points: [TransferFunctionPoint(frequency: 500, magnitudeDB: 10)],
            frequencyScale: averagingScale,
            capturedAtUptime: 6,
            blockDuration: 1
        )
        if settledStepAverage.first?.magnitudeDB != 10
            || constantStepAverage.first?.magnitudeDB != 10 {
            failures.append("Transfer function average did not settle after its five-second window")
        }
        let changedScaleAverage = curveAverager.average(
            points: [TransferFunctionPoint(frequency: 500, magnitudeDB: 30)],
            frequencyScale: alternateAveragingScale,
            capturedAtUptime: 4,
            blockDuration: 1
        )
        let reversedTimeAverage = curveAverager.average(
            points: [TransferFunctionPoint(frequency: 500, magnitudeDB: -10)],
            frequencyScale: alternateAveragingScale,
            capturedAtUptime: 4,
            blockDuration: 1
        )
        let invalidDurationAverage = curveAverager.average(
            points: [TransferFunctionPoint(frequency: 500, magnitudeDB: 4)],
            frequencyScale: alternateAveragingScale,
            capturedAtUptime: 4,
            blockDuration: .nan
        )
        curveAverager.reset()
        let resetAverage = curveAverager.average(
            points: [TransferFunctionPoint(frequency: 500, magnitudeDB: 7)],
            frequencyScale: averagingScale,
            capturedAtUptime: 0,
            blockDuration: 1
        )
        if changedScaleAverage.first?.magnitudeDB != 30
            || reversedTimeAverage.first?.magnitudeDB != -10
            || invalidDurationAverage.first?.magnitudeDB != 4
            || resetAverage.first?.magnitudeDB != 7 {
            failures.append("Transfer function average did not reset safely")
        }

        func coherencePoint(crossReal: Double, crossImaginary: Double) -> TransferFunctionPoint {
            let sums = TransferFunctionSpectralSums(
                referencePower: 1,
                measurementPower: 1,
                crossReal: crossReal,
                crossImaginary: crossImaginary
            )
            return TransferFunctionPoint(
                frequency: 500,
                magnitudeDB: 0,
                coherence: sums.coherence,
                spectralSums: sums
            )
        }
        var coherentAverager = TransferFunctionAverager()
        var incoherentAverager = TransferFunctionAverager()
        var coherentResult: [TransferFunctionPoint] = []
        var incoherentResult: [TransferFunctionPoint] = []
        for index in 0..<2 {
            coherentResult = coherentAverager.average(
                points: [coherencePoint(crossReal: 1, crossImaginary: 0)],
                frequencyScale: averagingScale,
                capturedAtUptime: Double(index),
                blockDuration: 1
            )
            // Per-block coherence is 1, but the cross-spectra cancel between blocks.
            incoherentResult = incoherentAverager.average(
                points: [coherencePoint(crossReal: index == 0 ? 1 : -1, crossImaginary: 0)],
                frequencyScale: averagingScale,
                capturedAtUptime: Double(index),
                blockDuration: 1
            )
        }
        if abs((coherentResult.first?.coherence ?? 0) - 1) > 1e-9
            || (incoherentResult.first?.coherence ?? 1) > 1e-9 {
            failures.append(
                "Transfer function coherence was not derived from averaged cross-spectra"
            )
        }
        if TransferFunctionTraceData.opacity(forCoherence: 1)
                != TransferFunctionTraceData.maximumOpacity
            || TransferFunctionTraceData.opacity(forCoherence: 0)
                != TransferFunctionTraceData.minimumOpacity
            || TransferFunctionTraceData.opacity(forCoherence: .nan)
                != TransferFunctionTraceData.minimumOpacity
            || !(TransferFunctionTraceData.opacity(forCoherence: 0.55)
                > TransferFunctionTraceData.minimumOpacity
                && TransferFunctionTraceData.opacity(forCoherence: 0.55)
                < TransferFunctionTraceData.maximumOpacity) {
            failures.append("Transfer function coherence opacity mapping was wrong")
        }

        let sampleRate = 48_000.0
        let count = TransferFunctionDSP.analysisFrameCount(sampleRate: sampleRate)
        let delay = 480
        let gain = 0.5
        var state: UInt64 = 0x1234_5678
        var reference = [Float](repeating: 0, count: count)
        for index in reference.indices {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let normalized = Double(Int64(bitPattern: state)) / Double(Int64.max)
            reference[index] = Float(0.2 * normalized)
        }
        var measurement = [Float](repeating: 0, count: count)
        for index in delay..<count {
            measurement[index] = Float(gain) * reference[index - delay]
        }
        let analysis = TransferFunctionDSP.analyze(
            frame: TransferSignalFrame(
                measurement: measurement,
                reference: reference,
                sampleRate: sampleRate,
                capturedAtUptime: 1
            ),
            range: .focused
        )
        guard let curve = analysis.curve, analysis.validity == .valid else {
            failures.append("Transfer function rejected a valid delayed broadband reference")
            return
        }
        if abs(curve.delaySeconds - Double(delay) / sampleRate) > 2 / sampleRate {
            failures.append("Transfer function did not align the impulse-response delay")
        }
        let middleLevels = curve.points
            .filter { $0.frequency >= 200 && $0.frequency <= 5_000 }
            .map(\.magnitudeDB)
            .sorted()
        let medianLevel = middleLevels.isEmpty
            ? .infinity
            : middleLevels[middleLevels.count / 2]
        if abs(medianLevel - 20 * log10(gain)) > 1.0 {
            failures.append("Transfer function did not recover a known broadband gain")
        }
        for smoothing in [TransferFunctionSmoothing.oneFortyEighth, .oneOctave] {
            let smoothingAnalysis = TransferFunctionDSP.analyze(
                frame: TransferSignalFrame(
                    measurement: measurement,
                    reference: reference,
                    sampleRate: sampleRate,
                    capturedAtUptime: 1
                ),
                range: .focused,
                smoothing: smoothing
            )
            let smoothedLevels = TransferFunctionDSP.smoothed(
                smoothingAnalysis.curve?.points ?? [],
                smoothing: smoothing
            )
            .filter { $0.frequency >= 200 && $0.frequency <= 5_000 }
            .map(\.magnitudeDB)
            .sorted()
            let smoothedMedian = smoothedLevels.isEmpty
                ? .infinity
                : smoothedLevels[smoothedLevels.count / 2]
            if smoothingAnalysis.validity != .valid
                || abs(smoothedMedian - 20 * log10(gain)) > 1.0 {
                failures.append(
                    "Transfer function with \(smoothing.bandsPerOctave)-band smoothing did not recover a known gain"
                )
            }
        }
        let automaticGainPoints = curve.points.filter {
            TransferFunctionDSP.automaticGainFrequencyRange.contains($0.frequency)
        }
        if curve.displayLowerDB > (automaticGainPoints.map(\.magnitudeDB).min() ?? 0)
            || curve.displayUpperDB < (automaticGainPoints.map(\.magnitudeDB).max() ?? 0) {
            failures.append("Transfer function AutoGain did not cover the 500-4000 Hz band")
        }

        func dynamicReference(seed: UInt64, envelopeOffset: Int) -> [Float] {
            var randomState = seed
            var previous = 0.0
            return (0..<count).map { index in
                randomState = randomState &* 6_364_136_223_846_793_005 &+ 1
                let white = Double(Int64(bitPattern: randomState)) / Double(Int64.max)
                let colored = 0.35 * white + 0.65 * previous
                previous = colored
                let block = ((index + envelopeOffset) / 768) % 5
                let envelope = block == 0 ? 1.0 : 0.12
                return Float(0.25 * envelope * colored)
            }
        }
        func delayedAnalysis(reference: [Float], delay: Int) -> TransferFunctionAnalysis {
            var measured = [Float](repeating: 0, count: reference.count)
            for index in delay..<reference.count {
                measured[index] = Float(gain) * reference[index - delay]
            }
            return TransferFunctionDSP.analyze(
                frame: TransferSignalFrame(
                    measurement: measured,
                    reference: reference,
                    sampleRate: sampleRate,
                    capturedAtUptime: 2
                ),
                range: .focused
            )
        }
        func medianDynamicLevel(_ curve: TransferFunctionCurve) -> Double {
            let levels = curve.points
                .filter { $0.frequency >= 200 && $0.frequency <= 12_000 }
                .map(\.magnitudeDB)
                .sorted()
            return levels.isEmpty ? .infinity : levels[levels.count / 2]
        }
        let dynamicDelay = Int(0.050 * sampleRate)
        let firstDynamicAnalysis = delayedAnalysis(
            reference: dynamicReference(seed: 0x9876_5432, envelopeOffset: 0),
            delay: dynamicDelay
        )
        let secondDynamicAnalysis = delayedAnalysis(
            reference: dynamicReference(seed: 0x1357_2468, envelopeOffset: 431),
            delay: dynamicDelay
        )
        if let firstDynamicCurve = firstDynamicAnalysis.curve,
           let secondDynamicCurve = secondDynamicAnalysis.curve {
            let expectedLevel = 20 * log10(gain)
            let firstLevel = medianDynamicLevel(firstDynamicCurve)
            let secondLevel = medianDynamicLevel(secondDynamicCurve)
            if abs(firstLevel - expectedLevel) > 0.25
                || abs(secondLevel - expectedLevel) > 0.25
                || abs(firstLevel - secondLevel) > 0.1
                || (firstDynamicCurve.points.last?.frequency ?? 0) < 8_000
                || (secondDynamicCurve.points.last?.frequency ?? 0) < 8_000 {
                failures.append(
                    String(
                        format: "Transfer function dynamic-reference levels varied: %.2f/%.2f dB, high %.0f/%.0f Hz",
                        firstLevel,
                        secondLevel,
                        firstDynamicCurve.points.last?.frequency ?? 0,
                        secondDynamicCurve.points.last?.frequency ?? 0
                    )
                )
            }
        } else {
            failures.append("Transfer function rejected a delayed dynamic broadband reference")
        }

        var noisyCurveAverager = TransferFunctionAverager()
        var settledNoisyLevels: [Double] = []
        let monitoredFrequencies = [500.0, 1_000, 4_000, 8_000]
        let maximumMonitoredFrequencyRatio = pow(2, 1.0 / 24)
        let expectedSettledObservationCount = 5
        var settledNoisyBandLevels: [Double: [Double]] = [:]
        var noiseState: UInt64 = 0x2468_1357
        let reflectionDelay = Int(0.007 * sampleRate)
        let blockDuration = Double(count) / sampleRate
        for observationIndex in 0..<16 {
            let dynamicReference = dynamicReference(
                seed: UInt64(observationIndex + 1) &* 0x1234_5678,
                envelopeOffset: observationIndex * 173
            )
            var noisyMeasurement = [Float](repeating: 0, count: count)
            for index in dynamicDelay..<count {
                noiseState = noiseState &* 6_364_136_223_846_793_005 &+ 1
                let independentNoise = Double(Int64(bitPattern: noiseState))
                    / Double(Int64.max)
                var value = gain * Double(dynamicReference[index - dynamicDelay])
                if index >= dynamicDelay + reflectionDelay {
                    value += 0.2 * gain
                        * Double(dynamicReference[index - dynamicDelay - reflectionDelay])
                }
                noisyMeasurement[index] = Float(value + 0.004 * independentNoise)
            }
            let noisyAnalysis = TransferFunctionDSP.analyze(
                frame: TransferSignalFrame(
                    measurement: noisyMeasurement,
                    reference: dynamicReference,
                    sampleRate: sampleRate,
                    capturedAtUptime: Double(observationIndex) * blockDuration
                ),
                range: .focused
            )
            guard let noisyCurve = noisyAnalysis.curve else {
                failures.append("Transfer function rejected a correlated noisy measurement")
                break
            }
            let averagedPoints = noisyCurveAverager.average(
                points: noisyCurve.points,
                frequencyScale: noisyCurve.frequencyScale,
                capturedAtUptime: noisyCurve.capturedAtUptime,
                blockDuration: blockDuration
            )
            let averagedCurve = TransferFunctionCurve(
                points: averagedPoints,
                frequencyScale: noisyCurve.frequencyScale,
                delaySeconds: noisyCurve.delaySeconds,
                displayLowerDB: noisyCurve.displayLowerDB,
                displayUpperDB: noisyCurve.displayUpperDB,
                capturedAtUptime: noisyCurve.capturedAtUptime
            )
            if observationIndex >= 11 {
                settledNoisyLevels.append(medianDynamicLevel(averagedCurve))
                for monitoredFrequency in monitoredFrequencies {
                    if let nearestPoint = averagedPoints.min(by: {
                        abs($0.frequency - monitoredFrequency)
                            < abs($1.frequency - monitoredFrequency)
                    }), max(
                        nearestPoint.frequency / monitoredFrequency,
                        monitoredFrequency / nearestPoint.frequency
                    ) <= maximumMonitoredFrequencyRatio + 1e-12 {
                        settledNoisyBandLevels[monitoredFrequency, default: []]
                            .append(nearestPoint.magnitudeDB)
                    }
                }
            }
        }
        for monitoredFrequency in monitoredFrequencies {
            let levels = settledNoisyBandLevels[monitoredFrequency] ?? []
            guard levels.count == expectedSettledObservationCount else {
                failures.append(
                    String(
                        format: "Transfer function %.0f Hz noisy coverage had %d/%d observations",
                        monitoredFrequency,
                        levels.count,
                        expectedSettledObservationCount
                    )
                )
                continue
            }
            if let minimum = levels.min(),
               let maximum = levels.max(),
               maximum - minimum > 0.5 {
                failures.append(
                    String(
                        format: "Transfer function %.0f Hz noisy average varied by %.2f dB",
                        monitoredFrequency,
                        maximum - minimum
                    )
                )
            }
        }
        if let minimumNoisyLevel = settledNoisyLevels.min(),
           let maximumNoisyLevel = settledNoisyLevels.max(),
           maximumNoisyLevel - minimumNoisyLevel > 0.25 {
            failures.append(
                String(
                    format: "Transfer function noisy-reflection average varied by %.2f dB",
                    maximumNoisyLevel - minimumNoisyLevel
                )
            )
        }

        let directDelay = Int(0.010 * sampleRate)
        let reflectedDelay = Int(0.020 * sampleRate)
        func multipathMeasurement(directGain: Double, reflectedGain: Double) -> [Float] {
            var measured = [Float](repeating: 0, count: count)
            for index in directDelay..<count {
                var value = directGain * Double(reference[index - directDelay])
                if index >= reflectedDelay {
                    value += reflectedGain * Double(reference[index - reflectedDelay])
                }
                measured[index] = Float(value)
            }
            return measured
        }
        func multipathAnalysis(
            directGain: Double,
            reflectedGain: Double,
            preferredDelay: Double? = nil
        ) -> TransferFunctionAnalysis {
            TransferFunctionDSP.analyze(
                frame: TransferSignalFrame(
                    measurement: multipathMeasurement(
                        directGain: directGain,
                        reflectedGain: reflectedGain
                    ),
                    reference: reference,
                    sampleRate: sampleRate,
                    capturedAtUptime: 4
                ),
                range: .focused,
                preferredDelaySamples: preferredDelay
            )
        }
        let directDominant = multipathAnalysis(directGain: 0.55, reflectedGain: 0.5)
        let reflectionDominant = multipathAnalysis(directGain: 0.5, reflectedGain: 0.55)
        let lockedReflectionDominant = multipathAnalysis(
            directGain: 0.5,
            reflectedGain: 0.55,
            preferredDelay: Double(directDelay)
        )
        let changedArrival = multipathAnalysis(
            directGain: 0.1,
            reflectedGain: 0.8,
            preferredDelay: Double(directDelay)
        )
        let missingPreferredArrival = multipathAnalysis(
            directGain: 0,
            reflectedGain: 0.8,
            preferredDelay: Double(directDelay)
        )
        let directDominantDelay = directDominant.curve?.delaySeconds ?? -.infinity
        let reflectionDominantDelay = reflectionDominant.curve?.delaySeconds ?? -.infinity
        let lockedDelay = lockedReflectionDominant.curve?.delaySeconds ?? -.infinity
        let changedDelay = changedArrival.curve?.delaySeconds ?? -.infinity
        let missingPreferredDelay = missingPreferredArrival.curve?.delaySeconds ?? -.infinity
        let delayTolerance = 2 / sampleRate
        if abs(directDominantDelay - Double(directDelay) / sampleRate) > delayTolerance
            || abs(reflectionDominantDelay - Double(reflectedDelay) / sampleRate) > delayTolerance
            || abs(lockedDelay - Double(directDelay) / sampleRate) > delayTolerance
            || abs(changedDelay - Double(reflectedDelay) / sampleRate) > delayTolerance
            || abs(missingPreferredDelay - Double(reflectedDelay) / sampleRate)
                > delayTolerance {
            failures.append(
                String(
                    format: "Transfer function delay hysteresis failed: %.3f/%.3f/%.3f/%.3f/%.3f s",
                    directDominantDelay,
                    reflectionDominantDelay,
                    lockedDelay,
                    changedDelay,
                    missingPreferredDelay
                )
            )
        }

        let count96 = TransferFunctionDSP.analysisFrameCount(sampleRate: 96_000)
        let lowFrequencyWindow48 = TransferFunctionDSP.windowDuration(
            for: 50,
            sampleRate: 48_000,
            frameCount: count
        )
        let lowFrequencyWindow96 = TransferFunctionDSP.windowDuration(
            for: 50,
            sampleRate: 96_000,
            frameCount: count96
        )
        let highFrequencyWindow48 = TransferFunctionDSP.windowDuration(
            for: 10_000,
            sampleRate: 48_000,
            frameCount: count
        )
        if abs(lowFrequencyWindow48 - 0.120) > 1e-12
            || abs(lowFrequencyWindow96 - 0.120) > 1e-12
            || abs(highFrequencyWindow48 - 0.004) > 1e-12
            || lowFrequencyWindow48 <= highFrequencyWindow48
            || lowFrequencyWindow96 != lowFrequencyWindow48 {
            failures.append("Transfer function did not use frequency-dependent IR time windows")
        }
        let delayLimit48 = TransferFunctionDSP.maximumDetectableDelay(
            sampleRate: 48_000,
            frameCount: count
        )
        let delayLimit96 = TransferFunctionDSP.maximumDetectableDelay(
            sampleRate: 96_000,
            frameCount: count96
        )
        if abs(delayLimit48 - 0.100) > 1e-12
            || abs(delayLimit96 - 0.100) > 1e-12 {
            failures.append("Transfer function delay limit did not match its FFT frame")
        }
        for rate in [32_000.0, 44_100.0, 48_000.0, 96_000.0, 192_000.0] {
            let frameCount = TransferFunctionDSP.analysisFrameCount(sampleRate: rate)
            let halfDuration = Double(frameCount / 2 - 1) / rate
            let fullDuration = Double(frameCount) / rate
            if frameCount.nonzeroBitCount != 1
                || halfDuration < 0.122
                || fullDuration < 0.222 {
                failures.append("Transfer function frame was too short at \(rate) Hz")
            }
        }
        if !TransferFunctionDSP.framesAreContinuous(
            expectedNextUptime: 10,
            nextUptime: 10 + 1 / 96_000,
            sampleRate: 96_000
        ) || TransferFunctionDSP.framesAreContinuous(
            expectedNextUptime: 10,
            nextUptime: 10 + Double(SpectrogramAnalyzer.fftSize) / 96_000,
            sampleRate: 96_000
        ) {
            failures.append("Transfer function did not detect a timestamp discontinuity")
        }
        var reflectedImpulse = [Double](repeating: 0, count: count)
        reflectedImpulse[0] = 1
        reflectedImpulse[Int(0.020 * sampleRate)] = 0.5
        let lowFrequencyMagnitude = TransferFunctionDSP.gatedMagnitude(
            impulseResponse: reflectedImpulse,
            frequency: 50,
            sampleRate: sampleRate
        )
        let highFrequencyMagnitude = TransferFunctionDSP.gatedMagnitude(
            impulseResponse: reflectedImpulse,
            frequency: 10_000,
            sampleRate: sampleRate
        )
        if lowFrequencyMagnitude < 1.4 || abs(highFrequencyMagnitude - 1) > 1e-9 {
            failures.append("Transfer function IR gate did not retain longer low-frequency decay")
        }

        let longDelaySampleRate = 96_000.0
        let longDelay = Int(longDelaySampleRate * 0.060)
        var longReference = [Float](repeating: 0, count: count96)
        for index in longReference.indices {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            longReference[index] = Float(
                0.2 * Double(Int64(bitPattern: state)) / Double(Int64.max)
            )
        }
        var longMeasurement = [Float](repeating: 0, count: count96)
        for index in longDelay..<count96 {
            longMeasurement[index] = Float(gain) * longReference[index - longDelay]
        }
        let longDelayAnalysis = TransferFunctionDSP.analyze(
            frame: TransferSignalFrame(
                measurement: longMeasurement,
                reference: longReference,
                sampleRate: longDelaySampleRate,
                capturedAtUptime: 3
            ),
            range: .focused
        )
        if longDelayAnalysis.validity != .valid
            || abs(
                (longDelayAnalysis.curve?.delaySeconds ?? 0)
                    - Double(longDelay) / longDelaySampleRate
            ) > 2 / longDelaySampleRate {
            failures.append("Transfer function did not recover a 60 ms delay at 96 kHz")
        }

        let silent = TransferFunctionDSP.analyze(
            frame: TransferSignalFrame(
                measurement: measurement,
                reference: Array(repeating: 0, count: count),
                sampleRate: sampleRate,
                capturedAtUptime: 2
            ),
            range: .focused
        )
        if silent.validity != .invalidReference || silent.curve != nil {
            failures.append("Transfer function produced a curve from a silent reference")
        }

        var unrelatedMeasurement = [Float](repeating: 0, count: count)
        for index in unrelatedMeasurement.indices {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            unrelatedMeasurement[index] = Float(
                0.2 * Double(Int64(bitPattern: state)) / Double(Int64.max)
            )
        }
        let unrelated = TransferFunctionDSP.analyze(
            frame: TransferSignalFrame(
                measurement: unrelatedMeasurement,
                reference: reference,
                sampleRate: sampleRate,
                capturedAtUptime: 3
            ),
            range: .focused
        )
        if unrelated.validity != .invalidReference || unrelated.curve != nil {
            failures.append("Transfer function accepted unrelated measurement and reference signals")
        }
    }

    private static func testTransferFunctionSmoothing(_ failures: inout [String]) {
        guard let scale = SpectrogramFrequencyScale(
            sampleRate: 48_000,
            frameCount: SpectrogramAnalyzer.fftSize,
            range: .focused
        ) else {
            failures.append("Transfer function smoothing scale was invalid")
            return
        }
        let frequencies = TransferFunctionDSP.gridFrequencies(for: scale)
        let spikeIndex = frequencies.count / 2
        guard spikeIndex >= TransferFunctionDSP.gridBandsPerOctave,
              spikeIndex + TransferFunctionDSP.gridBandsPerOctave < frequencies.count else {
            failures.append("Transfer function smoothing grid was too short")
            return
        }
        let flat = frequencies.map {
            TransferFunctionPoint(frequency: $0, magnitudeDB: -6, coherence: 0.9)
        }
        let spikeLevelDB = 12.0
        let spike = frequencies.indices.map { index in
            TransferFunctionPoint(
                frequency: frequencies[index],
                magnitudeDB: index == spikeIndex ? spikeLevelDB : 0,
                coherence: index == spikeIndex ? 0 : 1
            )
        }

        var previousPeak = Double.infinity
        for smoothing in TransferFunctionSmoothing.allCases {
            let smoothedFlat = TransferFunctionDSP.smoothed(flat, smoothing: smoothing)
            if smoothedFlat.count != flat.count
                || zip(smoothedFlat, flat).contains(where: { $0.frequency != $1.frequency })
                || smoothedFlat.contains(where: {
                    abs($0.magnitudeDB + 6) > 1e-9 || abs($0.coherence - 0.9) > 1e-9
                }) {
                failures.append(
                    "Transfer function \(smoothing.bandsPerOctave)-band smoothing changed a flat response"
                )
            }

            let smoothedSpike = TransferFunctionDSP.smoothed(spike, smoothing: smoothing)
            guard smoothedSpike.count == spike.count else {
                failures.append("Transfer function smoothing dropped points")
                continue
            }
            // A 1/N-octave band spans 48/N grid steps; the spike keeps full
            // weight and the remaining weight falls on 0 dB neighbours.
            let bandSteps = Double(TransferFunctionDSP.gridBandsPerOctave)
                / Double(smoothing.bandsPerOctave)
            let expectedPeak = bandSteps <= 1
                ? spikeLevelDB
                : 10 * log10((pow(10, spikeLevelDB / 10) + bandSteps - 1) / bandSteps)
            let expectedCoherence = bandSteps <= 1 ? 0 : (bandSteps - 1) / bandSteps
            let peak = smoothedSpike[spikeIndex].magnitudeDB
            if abs(peak - expectedPeak) > 1e-6
                || abs(smoothedSpike[spikeIndex].coherence - expectedCoherence) > 1e-6
                || peak > previousPeak + 1e-9 {
                failures.append(
                    String(
                        format: "Transfer function %d-band smoothing peak was %.3f dB, expected %.3f dB",
                        smoothing.bandsPerOctave,
                        peak,
                        expectedPeak
                    )
                )
            }
            previousPeak = peak
        }
        if TransferFunctionDSP.smoothed(spike, smoothing: .oneFortyEighth) != spike {
            failures.append("Transfer function 1/48-octave smoothing altered the analysis grid")
        }

        var gappedSpike = spike
        gappedSpike.remove(at: spikeIndex + 1)
        let smoothedGap = TransferFunctionDSP.smoothed(gappedSpike, smoothing: .oneSixth)
        if smoothedGap.count != gappedSpike.count
            || smoothedGap.contains(where: { !$0.magnitudeDB.isFinite }) {
            failures.append("Transfer function smoothing mishandled a missing band")
        }

        if TransferFunctionDSP.windowCycles(for: .default) != TransferFunctionDSP.cyclesInWindow
            || TransferFunctionDSP.windowCycles(for: .oneOctave) != TransferFunctionDSP.cyclesInWindow
            || TransferFunctionDSP.windowCycles(for: .oneFortyEighth) != 48
            || abs(
                TransferFunctionDSP.windowDuration(
                    for: 1_000,
                    sampleRate: 48_000,
                    frameCount: TransferFunctionDSP.analysisFrameCount(sampleRate: 48_000),
                    cycles: TransferFunctionDSP.windowCycles(for: .oneFortyEighth)
                ) - 0.048
            ) > 1e-12 {
            failures.append("Transfer function smoothing did not scale the IR window")
        }
    }

    private static func testTransferFunctionDisplayState(_ failures: inout [String]) {
        guard let frequencyScale = SpectrogramFrequencyScale(
            sampleRate: 48_000,
            frameCount: SpectrogramAnalyzer.fftSize,
            range: .focused
        ) else {
            failures.append("Transfer function display retention scale was invalid")
            return
        }
        let firstCurve = TransferFunctionCurve(
            points: [TransferFunctionPoint(frequency: 1_000, magnitudeDB: -3)],
            frequencyScale: frequencyScale,
            delaySeconds: 0.01,
            displayLowerDB: -12,
            displayUpperDB: 12,
            capturedAtUptime: 10
        )
        let recoveredCurve = TransferFunctionCurve(
            points: [TransferFunctionPoint(frequency: 1_000, magnitudeDB: 2)],
            frequencyScale: frequencyScale,
            delaySeconds: 0.02,
            displayLowerDB: -8,
            displayUpperDB: 16,
            capturedAtUptime: 12
        )
        var displayState = TransferFunctionDisplayState()
        _ = displayState.update(
            with: TransferFunctionAnalysis(validity: .valid, curve: firstCurve),
            at: 10
        )
        let briefDropout = displayState.update(
            with: TransferFunctionAnalysis(validity: .invalidReference, curve: nil),
            at: 10.5
        )
        let repeatedDropout = displayState.update(
            with: TransferFunctionAnalysis(validity: .invalidReference, curve: nil),
            at: 10.75
        )
        if briefDropout.validity != .invalidReference
            || briefDropout.curve != firstCurve
            || repeatedDropout.curve != firstCurve
            || displayState.expire(at: 10.99) != nil
            || displayState.expire(at: 11.1) != nil {
            failures.append("Transfer function display did not retain a curve through a brief dropout")
        }
        let expiredDropout = displayState.update(
            with: TransferFunctionAnalysis(validity: .invalidReference, curve: nil),
            at: 11.15
        )
        if expiredDropout.validity != .invalidReference
            || expiredDropout.curve != nil
            || displayState.expire(at: 11.18) != nil {
            failures.append("Transfer function display did not expire a sustained dropout")
        }
        let afterExpiredDropout = displayState.update(
            with: TransferFunctionAnalysis(validity: .invalidReference, curve: nil),
            at: 11.2
        )
        if afterExpiredDropout.curve != nil {
            failures.append("Transfer function display restored an expired curve")
        }
        let recovered = displayState.update(
            with: TransferFunctionAnalysis(validity: .valid, curve: recoveredCurve),
            at: 12
        )
        if recovered.curve != recoveredCurve {
            failures.append("Transfer function display did not publish a recovered curve immediately")
        }
        displayState.reset()
        let afterReset = displayState.update(
            with: TransferFunctionAnalysis(validity: .waitingForSignal, curve: nil),
            at: 12.1
        )
        if afterReset.curve != nil || displayState.expire(at: 13) != nil {
            failures.append("Transfer function display restored a stale curve after reset")
        }

        var idleDisplayState = TransferFunctionDisplayState()
        _ = idleDisplayState.update(
            with: TransferFunctionAnalysis(validity: .valid, curve: firstCurve),
            at: 20
        )
        let idleExpiration = idleDisplayState.expire(at: 21)
        if idleExpiration?.validity != .waitingForSignal
            || idleExpiration?.curve != nil {
            failures.append("Transfer function display did not expire without new frames")
        }

        var activeDisplayState = TransferFunctionDisplayState()
        _ = activeDisplayState.update(
            with: TransferFunctionAnalysis(validity: .valid, curve: firstCurve),
            at: 40
        )
        activeDisplayState.noteInputActivity(capturedAtUptime: 40.9)
        let expirationAfterQueuedFrame = activeDisplayState.expire(at: 41)
        activeDisplayState.noteInputActivity(capturedAtUptime: 41.5)
        let expirationDuringDelayedAnalysis = activeDisplayState.expire(at: 41.9)
        if expirationAfterQueuedFrame != nil || expirationDuringDelayedAnalysis != nil {
            failures.append("Transfer function display expired while input frames remained active")
        }
        activeDisplayState.noteInputActivity(capturedAtUptime: 42.9)
        if activeDisplayState.expire(at: 42.99) != nil {
            failures.append("Transfer function display expired before the analysis silence limit")
        }
        let stalledAnalysisExpiration = activeDisplayState.expire(
            at: 40 + TransferFunctionDisplayState.maximumAnalysisSilenceDuration
        )
        if stalledAnalysisExpiration?.validity != .waitingForSignal
            || stalledAnalysisExpiration?.curve != nil {
            failures.append("Transfer function display retained a stale curve indefinitely")
        }

        var staleInputDisplayState = TransferFunctionDisplayState()
        _ = staleInputDisplayState.update(
            with: TransferFunctionAnalysis(validity: .valid, curve: firstCurve),
            at: 45
        )
        staleInputDisplayState.noteInputActivity(capturedAtUptime: 45.8)
        staleInputDisplayState.noteInputActivity(capturedAtUptime: 45.7)
        staleInputDisplayState.noteInputActivity(capturedAtUptime: .infinity)
        staleInputDisplayState.noteInputActivity(capturedAtUptime: 48.1)
        let beforeStaleInputExpiration = staleInputDisplayState.expire(at: 46.79)
        let staleInputExpiration = staleInputDisplayState.expire(at: 46.8)
        if beforeStaleInputExpiration != nil
            || staleInputExpiration?.validity != .waitingForSignal
            || staleInputExpiration?.curve != nil {
            failures.append("Transfer function display accepted stale or future input activity")
        }

        var invalidReferenceDisplayState = TransferFunctionDisplayState()
        _ = invalidReferenceDisplayState.update(
            with: TransferFunctionAnalysis(validity: .valid, curve: firstCurve),
            at: 50
        )
        invalidReferenceDisplayState.noteInputActivity(capturedAtUptime: 50.8)
        let invalidReference = invalidReferenceDisplayState.update(
            with: TransferFunctionAnalysis(validity: .invalidReference, curve: nil),
            at: 50.9
        )
        invalidReferenceDisplayState.noteInputActivity(capturedAtUptime: 51.2)
        for uptime in [50.93, 50.96] {
            _ = invalidReferenceDisplayState.update(
                with: TransferFunctionAnalysis(validity: .invalidReference, curve: nil),
                at: uptime
            )
        }
        let invalidReferenceExpiration = invalidReferenceDisplayState.expire(at: 51)
        if invalidReference.curve != firstCurve
            || invalidReferenceExpiration?.validity != .invalidReference
            || invalidReferenceExpiration?.curve != nil {
            failures.append("Transfer function input activity masked an invalid reference")
        }

        var resetActiveDisplayState = TransferFunctionDisplayState()
        _ = resetActiveDisplayState.update(
            with: TransferFunctionAnalysis(validity: .valid, curve: firstCurve),
            at: 60
        )
        resetActiveDisplayState.reset()
        resetActiveDisplayState.noteInputActivity(capturedAtUptime: 60.5)
        if resetActiveDisplayState.expire(at: 61.5) != nil {
            failures.append("Transfer function input activity restored a reset curve")
        }

        var recoveringDisplayState = TransferFunctionDisplayState()
        _ = recoveringDisplayState.update(
            with: TransferFunctionAnalysis(validity: .valid, curve: firstCurve),
            at: 30
        )
        _ = recoveringDisplayState.update(
            with: TransferFunctionAnalysis(validity: .invalidReference, curve: nil),
            at: 30.5
        )
        _ = recoveringDisplayState.update(
            with: TransferFunctionAnalysis(validity: .valid, curve: recoveredCurve),
            at: 30.75
        )
        let earlyRecoveryExpiration = recoveringDisplayState.expire(at: 31.1)
        let recoveryExpiration = recoveringDisplayState.expire(at: 31.75)
        if earlyRecoveryExpiration != nil
            || recoveryExpiration?.validity != .waitingForSignal
            || recoveryExpiration?.curve != nil {
            failures.append("Transfer function recovery did not start a fresh retention window")
        }
    }

    private static func testTransferFunctionTraceVector(_ failures: inout [String]) {
        let start = TransferFunctionTraceVector([0, 0.5])
        let end = TransferFunctionTraceVector([1, 0.25])
        var transition = end - start
        transition.scale(by: 0.25)
        if (start + transition).values != [0.25, 0.4375]
            || (start + .zero) != start {
            failures.append("Transfer function trace vector did not interpolate linearly")
        }

        guard let scale = SpectrogramFrequencyScale(
            sampleRate: 48_000,
            frameCount: SpectrogramAnalyzer.fftSize,
            range: .focused
        ), let alternateScale = SpectrogramFrequencyScale(
            sampleRate: 48_000,
            frameCount: SpectrogramAnalyzer.fftSize,
            range: .full
        ) else {
            failures.append("Transfer function trace scales were invalid")
            return
        }
        let frequencies = TransferFunctionDSP.gridFrequencies(for: scale)
        guard frequencies.count > 12 else {
            failures.append("Transfer function trace grid was too short")
            return
        }
        let firstIndex = 8
        let middleIndex = 10
        let lastIndex = 12
        let completePoints = [
            TransferFunctionPoint(frequency: frequencies[firstIndex], magnitudeDB: -4),
            TransferFunctionPoint(frequency: frequencies[middleIndex], magnitudeDB: 6),
            TransferFunctionPoint(frequency: frequencies[lastIndex], magnitudeDB: 4)
        ]
        let missingMiddlePoints = [completePoints[0], completePoints[2]]
        guard let complete = TransferFunctionTraceData(
            points: completePoints,
            frequencyScale: scale,
            displayLowerDB: -10,
            displayUpperDB: 10
        ), let missingMiddle = TransferFunctionTraceData(
            points: missingMiddlePoints,
            frequencyScale: scale,
            displayLowerDB: -10,
            displayUpperDB: 10
        ), let missingFirst = TransferFunctionTraceData(
            points: Array(completePoints.dropFirst()),
            frequencyScale: scale,
            displayLowerDB: -10,
            displayUpperDB: 10
        ), let missingLast = TransferFunctionTraceData(
            points: Array(completePoints.dropLast()),
            frequencyScale: scale,
            displayLowerDB: -10,
            displayUpperDB: 10
        ), let alternate = TransferFunctionTraceData(
            points: [TransferFunctionPoint(
                frequency: alternateScale.lowerFrequency,
                magnitudeDB: 0
            )],
            frequencyScale: alternateScale,
            displayLowerDB: -10,
            displayUpperDB: 10
        ) else {
            failures.append("Transfer function trace data could not be prepared")
            return
        }

        let completeValues = complete.positions.values
        let missingValues = missingMiddle.positions.values
        let firstHorizontal = scale.position(for: frequencies[firstIndex]) ?? -.infinity
        let middleHorizontal = scale.position(for: frequencies[middleIndex]) ?? -.infinity
        let lastHorizontal = scale.position(for: frequencies[lastIndex]) ?? -.infinity
        let horizontalTolerance = 1e-12
        if complete.topology != missingMiddle.topology
            || complete.topology != missingFirst.topology
            || complete.topology != missingLast.topology
            || complete.topology == alternate.topology
            || completeValues.count != frequencies.count * 2
            || missingValues.count != completeValues.count
            || missingFirst.positions.values.count != completeValues.count
            || missingLast.positions.values.count != completeValues.count {
            failures.append("Transfer function trace topology was not stable across missing bands")
        }
        if abs(missingValues[firstIndex * 2] - firstHorizontal) > horizontalTolerance
            || abs(missingValues[middleIndex * 2] - middleHorizontal) > horizontalTolerance
            || abs(missingValues[lastIndex * 2] - lastHorizontal) > horizontalTolerance
            || abs(missingValues[middleIndex * 2 + 1] - 0.5) > horizontalTolerance {
            failures.append("Transfer function trace did not interpolate a missing middle band")
        }
        var midpoint = missingMiddle.positions - complete.positions
        midpoint.scale(by: 0.5)
        midpoint = complete.positions + midpoint
        if midpoint.values.count != completeValues.count
            || abs(midpoint.values[middleIndex * 2] - middleHorizontal) > horizontalTolerance
            || abs(midpoint.values[middleIndex * 2 + 1] - 0.35) > horizontalTolerance {
            failures.append("Transfer function trace did not morph continuously across a missing band")
        }
        var missingFirstMidpoint = missingFirst.positions - complete.positions
        missingFirstMidpoint.scale(by: 0.5)
        missingFirstMidpoint = complete.positions + missingFirstMidpoint
        var missingLastMidpoint = missingLast.positions - complete.positions
        missingLastMidpoint.scale(by: 0.5)
        missingLastMidpoint = complete.positions + missingLastMidpoint
        if abs(
            missingFirstMidpoint.values[firstIndex * 2]
                - (firstHorizontal + middleHorizontal) / 2
        ) > horizontalTolerance
            || abs(missingFirstMidpoint.values[firstIndex * 2 + 1] - 0.45)
                > horizontalTolerance
            || abs(
                missingLastMidpoint.values[lastIndex * 2]
                    - (lastHorizontal + middleHorizontal) / 2
            ) > horizontalTolerance
            || abs(missingLastMidpoint.values[lastIndex * 2 + 1] - 0.25)
                > horizontalTolerance {
            failures.append("Transfer function trace did not morph a missing endpoint continuously")
        }
        if missingFirst.positions.values[..<(middleIndex * 2)].enumerated().contains(where: {
            index, value in index.isMultiple(of: 2) && abs(value - middleHorizontal) > horizontalTolerance
        }) || missingLast.positions.values[((middleIndex + 1) * 2)...].enumerated().contains(where: {
            index, value in index.isMultiple(of: 2) && abs(value - middleHorizontal) > horizontalTolerance
        }) || missingValues[..<(firstIndex * 2)].enumerated().contains(where: {
            index, value in index.isMultiple(of: 2) && abs(value - firstHorizontal) > horizontalTolerance
        }) || missingValues[((lastIndex + 1) * 2)...].enumerated().contains(where: {
            index, value in index.isMultiple(of: 2) && abs(value - lastHorizontal) > horizontalTolerance
        }) {
            failures.append("Transfer function trace extended a missing endpoint into a tail")
        }
        let invalidTraceData = TransferFunctionTraceData(
            points: Array(completePoints.reversed()),
            frequencyScale: scale,
            displayLowerDB: -10,
            displayUpperDB: 10
        )
        if invalidTraceData != nil
            || TransferFunctionTraceData(
                points: [],
                frequencyScale: scale,
                displayLowerDB: -10,
                displayUpperDB: 10
            ) != nil {
            failures.append("Transfer function trace accepted invalid point data")
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
