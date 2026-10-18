import Foundation

enum LoggingIntegrityTests {
    private final class LockedResults: @unchecked Sendable {
        private let lock = NSLock()
        private var errors: [Error] = []

        func append(_ error: Error) {
            lock.lock()
            errors.append(error)
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return errors.count
        }

        var first: Error? {
            lock.lock()
            defer { lock.unlock() }
            return errors.first
        }
    }

    static func run() -> [String] {
        var failures: [String] = []
        testSessionLifecycleAndGap(&failures)
        testInterruptedSessionInspection(&failures)
        testAcceptedBurstIsFullyPersisted(&failures)
        testQueueOverflowIsVisible(&failures)
        return failures
    }

    private static func testSessionLifecycleAndGap(_ failures: inout [String]) {
        withTemporaryFile { file in
            let session = makeSession(startedAt: Date(timeIntervalSince1970: 1_000))
            let logger = CSVMeasurementLogger()
            guard start(logger, at: file, session: session, failures: &failures) else { return }

            let errors = LockedResults()
            logger.append(makeSample(sessionID: session.id, timestamp: 1_001, second: 10)) {
                errors.append($0)
            }
            logger.append(makeSample(
                sessionID: session.id,
                timestamp: 1_003,
                second: 12,
                state: .invalid,
                metrics: nil
            )) { errors.append($0) }
            logger.append(MeasurementEvent(
                sessionID: session.id,
                timestamp: Date(timeIntervalSince1970: 1_004),
                type: .configurationChanged,
                metadata: ["profile": "concert, main"]
            )) { errors.append($0) }

            let stopErrors = LockedResults()
            logger.stop(waitUntilClosed: true) {
                if case let .failure(error) = $0 { stopErrors.append(error) }
            }
            if let error = errors.first ?? stopErrors.first {
                failures.append("Session logger returned an error: \(error.localizedDescription)")
                return
            }

            guard let contents = try? String(contentsOf: file, encoding: .utf8) else {
                failures.append("Session CSV could not be read")
                return
            }
            if !contents.contains("timestamp_utc,session_id,session_status,measurement_state") {
                failures.append("Session CSV is missing integrity columns")
            }
            if !contents.contains("laeq_1s_db,lceq_1s_db,lzeq_1s_db,lafmax_1s_db") {
                failures.append("Session CSV is missing mandatory one-second metric columns")
            }
            if !contents.contains("laeq_30_min_db,lceq_30_min_db") {
                failures.append("Session CSV has incorrect 30-minute metric columns")
            }
            if contents.contains("+00:00") || !contents.contains("Z,") {
                failures.append("Session CSV timestamps are not explicitly UTC")
            }
            if !contents.contains(",gap,") || !contents.contains(",1,,AudioDropout,") {
                failures.append("A missing completed-second sample did not produce a gap row")
            }
            if !contents.contains(",Invalid,One or more mandatory metrics unavailable,12,576000,") {
                failures.append("An invalid/silent second was not retained with its sequence")
            }
            if !contents.contains("ConfigurationChanged") || !contents.contains("concert, main") {
                failures.append("Event metadata was not exported")
            }
            do {
                let inspection = try CSVMeasurementLogger.inspectSession(at: file)
                if inspection?.sessionID != session.id || inspection?.status != .completed {
                    failures.append("A clean close was not identified as a completed session")
                }
            } catch {
                failures.append("Completed session inspection failed: \(error.localizedDescription)")
            }
        }
    }

    private static func testInterruptedSessionInspection(_ failures: inout [String]) {
        withTemporaryFile { file in
            let session = makeSession(startedAt: Date(timeIntervalSince1970: 2_000))
            let logger = CSVMeasurementLogger()
            guard start(logger, at: file, session: session, failures: &failures) else { return }

            let flushed = DispatchSemaphore(value: 0)
            let flushErrors = LockedResults()
            logger.flush {
                if case let .failure(error) = $0 { flushErrors.append(error) }
                flushed.signal()
            }
            guard flushed.wait(timeout: .now() + 2) == .success, flushErrors.first == nil else {
                failures.append("Active session could not be flushed")
                return
            }
            do {
                if try CSVMeasurementLogger.inspectSession(at: file)?.isUnfinished != true {
                    failures.append("An active recording was not identified as unfinished")
                }
            } catch {
                failures.append("Active session inspection failed: \(error.localizedDescription)")
            }

            logger.stop(finalStatus: .interrupted, waitUntilClosed: true)
            do {
                if try CSVMeasurementLogger.inspectSession(at: file)?.status != .interrupted {
                    failures.append("An interrupted close did not persist its final state")
                }
            } catch {
                failures.append("Interrupted session inspection failed: \(error.localizedDescription)")
            }
        }
    }

    private static func testQueueOverflowIsVisible(_ failures: inout [String]) {
        withTemporaryFile { file in
            let session = makeSession(startedAt: Date(timeIntervalSince1970: 3_000))
            let logger = CSVMeasurementLogger(maximumPendingWrites: 1)
            guard start(logger, at: file, session: session, failures: &failures) else { return }
            let errors = LockedResults()
            let largeValue = String(repeating: "x", count: 32_768)
            for index in 0..<100 {
                logger.append(MeasurementEvent(
                    sessionID: session.id,
                    timestamp: Date(timeIntervalSince1970: 3_001 + Double(index)),
                    type: .configurationChanged,
                    metadata: ["payload": largeValue]
                )) { errors.append($0) }
            }
            logger.stop(waitUntilClosed: true)
            if errors.count == 0 {
                failures.append("Bounded logger queue did not report overflow under load")
            }
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else {
                failures.append("Overflow CSV could not be read")
                return
            }
            if !contents.contains(",error,") || !contents.contains("BufferOverflow") {
                failures.append("Queue overflow was not persisted as an error row")
            }
        }
    }

    private static func testAcceptedBurstIsFullyPersisted(_ failures: inout [String]) {
        withTemporaryFile { file in
            let session = makeSession(startedAt: Date(timeIntervalSince1970: 2_500))
            let logger = CSVMeasurementLogger(
                maximumPendingWrites: 128,
                synchronizationInterval: 32
            )
            guard start(logger, at: file, session: session, failures: &failures) else { return }
            let errors = LockedResults()
            for index in 1...100 {
                logger.append(makeSample(
                    sessionID: session.id,
                    timestamp: 2_500 + Double(index),
                    second: UInt64(index)
                )) { errors.append($0) }
            }
            logger.stop(waitUntilClosed: true)
            if let error = errors.first {
                failures.append("Accepted sample burst returned an error: \(error.localizedDescription)")
                return
            }
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else {
                failures.append("Accepted sample burst CSV could not be read")
                return
            }
            let sampleRows = contents.components(separatedBy: ",sample,").count - 1
            if sampleRows != 100 {
                failures.append("Accepted sample burst persisted \(sampleRows) of 100 rows")
            }
        }
    }

    private static func makeSession(startedAt: Date) -> MeasurementSession {
        MeasurementSession(
            startedAt: startedAt,
            name: "Integrity test",
            location: "Test lab",
            note: "line one\nline two",
            deviceUID: "test,device",
            channel: 1,
            sampleRate: 48_000,
            calibrationOffset: 114.2,
            calibratedAt: startedAt.addingTimeInterval(-100),
            appVersion: "test",
            measurementConfiguration: ["interval": "1s"]
        )
    }

    private static func makeSample(
        sessionID: UUID,
        timestamp: TimeInterval,
        second: UInt64,
        state: MeasurementSampleState = .valid,
        metrics: Double? = 72
    ) -> MeasurementSample {
        MeasurementSample(
            sessionID: sessionID,
            timestamp: Date(timeIntervalSince1970: timestamp),
            completedSecondCount: second,
            processedFrameCount: second * 48_000,
            state: state,
            laeq1Second: metrics,
            lceq1Second: metrics.map { $0 + 3 },
            lzeq1Second: metrics.map { $0 + 1 },
            lafMax1Second: metrics.map { $0 + 4 },
            lasMax1Second: metrics.map { $0 + 2 },
            lcPeak1Second: metrics.map { $0 + 12 },
            laeq30Minutes: nil,
            lceq30Minutes: nil
        )
    }

    private static func start(
        _ logger: CSVMeasurementLogger,
        at file: URL,
        session: MeasurementSession,
        failures: inout [String]
    ) -> Bool {
        let finished = DispatchSemaphore(value: 0)
        let errors = LockedResults()
        logger.start(at: file, session: session) {
            if case let .failure(error) = $0 { errors.append(error) }
            finished.signal()
        }
        guard finished.wait(timeout: .now() + 2) == .success else {
            failures.append("Session logger start timed out")
            return false
        }
        if let error = errors.first {
            failures.append("Session logger could not start: \(error.localizedDescription)")
            return false
        }
        return true
    }

    private static func withTemporaryFile(_ body: (URL) -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SPLManLoggingTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        body(directory.appendingPathComponent("measurement.csv"))
    }
}
