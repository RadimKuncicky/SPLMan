import Foundation

struct CompletedSecondRecorderUpdate: Sendable {
    let dropoutCount: Int
    let clippingDetected: Bool
    let exceededLimits: Set<Metric>
}

final class CompletedSecondRecorder: @unchecked Sendable {
    typealias UpdateHandler = @Sendable (CompletedSecondRecorderUpdate) -> Void
    typealias ErrorHandler = @Sendable (Error) -> Void

    private let engine: AudioCaptureEngine
    private let logger: CSVMeasurementLogger
    private let sessionID: UUID
    private let sessionStartedAt: Date
    private let calibrationOffset: Double
    private let queue = DispatchQueue(label: "cz.splman.completed-second-recorder", qos: .utility)
    private let onUpdate: UpdateHandler
    private let onError: ErrorHandler
    private var timer: DispatchSourceTimer?
    private var alarmSettings: AlarmSettings
    private var lastCompletedSecondCount: UInt64?
    private var lastTimestamp: Date?
    private var hasAppendedSample = false
    private var dropoutCount = 0
    private var clippingDetected = false
    private var exceededLimits: Set<Metric> = []

    init(
        engine: AudioCaptureEngine,
        logger: CSVMeasurementLogger,
        sessionID: UUID,
        calibrationOffset: Double,
        alarmSettings: AlarmSettings,
        initialCompletedSecondCount: UInt64?,
        sessionStartedAt: Date,
        initialDropoutCount: Int,
        initialClippingDetected: Bool,
        onUpdate: @escaping UpdateHandler,
        onError: @escaping ErrorHandler
    ) {
        self.engine = engine
        self.logger = logger
        self.sessionID = sessionID
        self.sessionStartedAt = sessionStartedAt
        self.calibrationOffset = calibrationOffset
        self.alarmSettings = alarmSettings
        lastCompletedSecondCount = initialCompletedSecondCount
        lastTimestamp = sessionStartedAt
        dropoutCount = initialDropoutCount
        clippingDetected = initialClippingDetected
        self.onUpdate = onUpdate
        self.onError = onError
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.drain() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            // Gap rows are written from interval-attached counts so they stay
            // in stream order. Only what the stream reports after the last
            // drained interval becomes a trailing gap; health event counters
            // are not used for this because they are read at a different
            // moment than the queue and would race with it.
            let tail = engine.currentStreamTail()
            drain()
            appendTrailingGapIfNeeded(tail)
        }
    }

    func updateConfiguration(
        alarmSettings: AlarmSettings,
        displayedMetrics: [Metric]
    ) {
        queue.async { [self] in
            let wasEnabled = self.alarmSettings.isEnabled
            self.alarmSettings = alarmSettings
            logger.append(MeasurementEvent(
                sessionID: sessionID,
                type: .configurationChanged,
                metadata: [
                    "displayed_metrics": displayedMetrics.map(\.rawValue).joined(separator: ";"),
                    "alarm_enabled": String(alarmSettings.isEnabled),
                    "laeq_30_min_limit_db": Self.number(alarmSettings.laeq30MinuteLimit),
                    "lcpeak_limit_db": Self.number(alarmSettings.lcPeakLimit)
                ]
            ), onError: onError)
            if wasEnabled, !alarmSettings.isEnabled, !exceededLimits.isEmpty {
                for metric in exceededLimits {
                    logger.append(MeasurementEvent(
                        sessionID: sessionID,
                        type: .alarmCleared,
                        metadata: [
                            "metric": metric.rawValue,
                            "reason": "Alarm monitoring disabled"
                        ]
                    ), onError: onError)
                }
                exceededLimits.removeAll()
                publishUpdate()
            }
        }
    }

    func recordEvent(_ type: MeasurementEventType, metadata: [String: String]) {
        queue.async { [self] in
            logger.append(MeasurementEvent(
                sessionID: sessionID,
                type: type,
                metadata: metadata
            ), onError: onError)
        }
    }

    private func drain() {
        let health = engine.takeHealthEvents()
        var didChangeStatus = false
        if health.clippedFrameCount > 0 {
            clippingDetected = true
            didChangeStatus = true
            logger.append(MeasurementEvent(
                sessionID: sessionID,
                type: .clippingDetected,
                metadata: ["clipped_frame_count": String(health.clippedFrameCount)]
            ), onError: onError)
        }
        if health.audioDropoutCount > 0 || health.renderErrorCount > 0 {
            let increment = health.audioDropoutCount + health.renderErrorCount
            dropoutCount += Int(clamping: increment)
            didChangeStatus = true
            var metadata = [
                "audio_dropout_count": String(health.audioDropoutCount),
                "render_error_count": String(health.renderErrorCount),
                "missing_frame_count": String(health.missingFrameCount),
                "discarded_partial_frame_count": String(health.discardedPartialFrameCount)
            ]
            if let status = health.lastRenderStatus {
                metadata["last_render_status"] = String(status)
            }
            logger.append(MeasurementEvent(
                sessionID: sessionID,
                type: .audioDropout,
                metadata: metadata
            ), onError: onError)
        }
        if health.droppedSecondIntervalCount > 0 {
            dropoutCount += Int(clamping: health.droppedSecondIntervalCount)
            didChangeStatus = true
            logger.append(MeasurementEvent(
                sessionID: sessionID,
                type: .bufferOverflow,
                metadata: [
                    "dropped_second_interval_count": String(health.droppedSecondIntervalCount)
                ]
            ), onError: onError)
        }

        while let completed = engine.takeCompletedSecond() {
            append(completed)
        }
        if didChangeStatus {
            publishUpdate()
        }
    }

    private func append(_ completed: CompletedAudioSecond) {
        let raw = completed.snapshot
        let intervalStart = completed.intervalEndUTC.addingTimeInterval(-1)
        if completed.precedingDiscontinuityEvents > 0 {
            // A discontinuity before the first full post-REC interval is
            // already covered by the initial partial-second exclusion.
            if hasAppendedSample || intervalStart >= sessionStartedAt {
                logger.appendGap(Self.makeDiscontinuityGap(
                    sessionID: sessionID,
                    lastIntervalEnd: lastTimestamp,
                    nextIntervalStart: intervalStart,
                    sessionStartedAt: sessionStartedAt,
                    eventCount: completed.precedingDiscontinuityEvents,
                    missingFrameCount: completed.precedingMissingFrames,
                    discardedPartialFrameCount: completed.precedingDiscardedPartialFrames
                ), onError: onError)
            }
        }
        if let previous = lastCompletedSecondCount,
           raw.completedSecondCount > previous + 1 {
            let sequenceGap = raw.completedSecondCount - previous - 1
            logger.appendGap(Self.makeSequenceGap(
                sessionID: sessionID,
                lastIntervalEnd: lastTimestamp ?? sessionStartedAt,
                nextIntervalStart: intervalStart,
                lostSecondIntervals: sequenceGap,
                atRecordingStart: !hasAppendedSample
            ), onError: onError)
        }

        if !hasAppendedSample,
           !Self.isFullIntervalAfterRecordingStart(
               intervalEndUTC: completed.intervalEndUTC,
               sessionStartedAt: sessionStartedAt
           ) {
            if completed.intervalEndUTC > sessionStartedAt {
                logger.appendGap(MeasurementGap(
                    sessionID: sessionID,
                    startedAt: sessionStartedAt,
                    endedAt: completed.intervalEndUTC,
                    lostSecondIntervals: 1,
                    reason: "Initial partial second excluded after recording start"
                ), onError: onError)
            }
            lastCompletedSecondCount = raw.completedSecondCount
            return
        }

        let laeq1Second = calibrated(raw.laeq1Second)
        let lceq1Second = calibrated(raw.lceq1Second)
        let lafMax1Second = calibrated(raw.lafMax1Second)
        let lcPeak1Second = calibrated(raw.lcPeak1Second)
        let requiredValues = [laeq1Second, lceq1Second, lafMax1Second, lcPeak1Second]
        let state: MeasurementSampleState = requiredValues.allSatisfy {
            $0?.isFinite == true
        } ? .valid : .invalid

        let sample = MeasurementSample(
            sessionID: sessionID,
            timestamp: completed.intervalEndUTC,
            completedSecondCount: raw.completedSecondCount,
            processedFrameCount: raw.processedFrameCount,
            state: state,
            stateReason: state == .invalid
                ? "Digital silence or mandatory metric unavailable" : nil,
            laeq1Second: laeq1Second,
            lceq1Second: lceq1Second,
            lzeq1Second: calibrated(raw.lzeq1Second),
            lafMax1Second: lafMax1Second,
            lasMax1Second: calibrated(raw.lasMax1Second),
            lcPeak1Second: lcPeak1Second,
            laeq30Minutes: calibrated(raw.laeq30),
            lceq30Minutes: calibrated(raw.lceq30),
            laeq1Minute: calibrated(raw.laeq1),
            laeq10Minutes: calibrated(raw.laeq10),
            laeq15Minutes: calibrated(raw.laeq15),
            lceq1Minute: calibrated(raw.lceq1),
            lceq10Minutes: calibrated(raw.lceq10),
            aSlow: calibrated(raw.aSlow),
            cSlow: calibrated(raw.cSlow),
            cMinusA1Minute: difference(raw.lceq1, raw.laeq1),
            cMinusA10Minutes: difference(raw.lceq10, raw.laeq10),
            cMinusASlow: difference(raw.cSlow, raw.aSlow)
        )
        logger.append(sample, onError: onError)
        lastCompletedSecondCount = raw.completedSecondCount
        lastTimestamp = completed.intervalEndUTC
        hasAppendedSample = true
        updateAlarms(for: raw, timestamp: completed.intervalEndUTC)
    }

    private func updateAlarms(for raw: RawMeterSnapshot, timestamp: Date) {
        var current = exceededLimits
        if alarmSettings.isEnabled {
            updateAlarm(
                .laeq30,
                raw.laeq30,
                limit: alarmSettings.laeq30MinuteLimit,
                in: &current
            )
            updateAlarm(
                .lcPeak1Second,
                raw.lcPeak1Second,
                limit: alarmSettings.lcPeakLimit,
                in: &current
            )
        } else {
            current.removeAll()
        }

        let triggered = current.subtracting(exceededLimits)
        let cleared = exceededLimits.subtracting(current)
        for metric in triggered {
            logger.append(MeasurementEvent(
                sessionID: sessionID,
                timestamp: timestamp,
                type: .alarmTriggered,
                metadata: alarmMetadata(for: metric, raw: raw)
            ), onError: onError)
        }
        for metric in cleared {
            logger.append(MeasurementEvent(
                sessionID: sessionID,
                timestamp: timestamp,
                type: .alarmCleared,
                metadata: alarmMetadata(for: metric, raw: raw)
            ), onError: onError)
        }
        guard current != exceededLimits else { return }
        exceededLimits = current
        publishUpdate()
    }

    private func updateAlarm(
        _ metric: Metric,
        _ rawValue: Double?,
        limit: Double,
        in values: inout Set<Metric>
    ) {
        guard let value = calibrated(rawValue) else {
            values.remove(metric)
            return
        }
        if value >= limit {
            values.insert(metric)
        } else {
            values.remove(metric)
        }
    }

    private func alarmMetadata(for metric: Metric, raw: RawMeterSnapshot) -> [String: String] {
        let rawValue: Double?
        let limit: Double
        switch metric {
        case .laeq30:
            rawValue = raw.laeq30
            limit = alarmSettings.laeq30MinuteLimit
        case .lcPeak1Second:
            rawValue = raw.lcPeak1Second
            limit = alarmSettings.lcPeakLimit
        default:
            rawValue = nil
            limit = 0
        }
        var metadata = [
            "metric": metric.rawValue,
            "limit_db": Self.number(limit)
        ]
        if let value = calibrated(rawValue) {
            metadata["value_db"] = Self.number(value)
        } else {
            metadata["reason"] = "Metric unavailable"
        }
        return metadata
    }

    private func appendTrailingGapIfNeeded(_ tail: AudioStreamTail?) {
        let endedAt = Date()
        let loss = Self.trailingLoss(
            tail: tail,
            lastTakenCompletedSecondCount: lastCompletedSecondCount
        )
        if loss.discontinuityEvents > 0 {
            logger.appendGap(Self.makeDiscontinuityGap(
                sessionID: sessionID,
                lastIntervalEnd: lastTimestamp,
                nextIntervalStart: endedAt,
                sessionStartedAt: sessionStartedAt,
                eventCount: loss.discontinuityEvents,
                missingFrameCount: loss.missingFrames,
                discardedPartialFrameCount: loss.discardedPartialFrames
            ), onError: onError)
        }

        guard loss.droppedIntervals > 0 else { return }
        // `lastTimestamp` is the end of the last logged interval, which is
        // where the undelivered intervals begin.
        let startedAt = min(
            endedAt,
            lastTimestamp ?? endedAt.addingTimeInterval(-Double(loss.droppedIntervals))
        )
        logger.appendGap(MeasurementGap(
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: endedAt,
            lostSecondIntervals: loss.droppedIntervals,
            reason: "Completed-second buffer overflow"
        ), onError: onError)
    }

    struct TrailingLoss: Equatable {
        var discontinuityEvents: UInt64 = 0
        var missingFrames: UInt64 = 0
        var discardedPartialFrames: UInt64 = 0
        var droppedIntervals: UInt64 = 0
    }

    /// What happened after the last interval taken from the queue. `tail`
    /// must be read before the final drain, so every interval it counts was
    /// either drained (and its attached events logged) or dropped.
    static func trailingLoss(
        tail: AudioStreamTail?,
        lastTakenCompletedSecondCount: UInt64?
    ) -> TrailingLoss {
        guard let tail else { return TrailingLoss() }
        var loss = TrailingLoss()
        // Pending discontinuities belong to no drained interval only if no
        // interval was delivered after the one taken last. Otherwise they were
        // attached to a later interval, which already produced its gap row.
        if lastTakenCompletedSecondCount == nil
            || tail.lastDeliveredCompletedSecondCount == lastTakenCompletedSecondCount {
            loss.discontinuityEvents = tail.pendingDiscontinuityEvents
            loss.missingFrames = tail.pendingMissingFrames
            loss.discardedPartialFrames = tail.pendingDiscardedPartialFrames
        }
        // Intervals completed after the last taken one were dropped; drops
        // between taken intervals were already logged as sequence gaps.
        if let lastTaken = lastTakenCompletedSecondCount,
           tail.completedSecondCount > lastTaken {
            loss.droppedIntervals = tail.completedSecondCount - lastTaken
        }
        return loss
    }

    private func calibrated(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value + calibrationOffset
    }

    private func difference(_ cValue: Double?, _ aValue: Double?) -> Double? {
        guard let cValue, let aValue, cValue.isFinite, aValue.isFinite else { return nil }
        return cValue - aValue
    }

    private func publishUpdate() {
        onUpdate(CompletedSecondRecorderUpdate(
            dropoutCount: dropoutCount,
            clippingDetected: clippingDetected,
            exceededLimits: exceededLimits
        ))
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func isFullIntervalAfterRecordingStart(
        intervalEndUTC: Date,
        sessionStartedAt: Date
    ) -> Bool {
        intervalEndUTC.addingTimeInterval(-1) >= sessionStartedAt
    }

    /// Gap for completed-second intervals that were dropped (DSP or handoff
    /// queue overflow) between two delivered intervals.
    static func makeSequenceGap(
        sessionID: UUID,
        lastIntervalEnd: Date,
        nextIntervalStart: Date,
        lostSecondIntervals: UInt64,
        atRecordingStart: Bool
    ) -> MeasurementGap {
        let startedAt = min(
            nextIntervalStart,
            max(
                lastIntervalEnd,
                nextIntervalStart.addingTimeInterval(-Double(lostSecondIntervals))
            )
        )
        return MeasurementGap(
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: nextIntervalStart,
            lostSecondIntervals: lostSecondIntervals,
            reason: atRecordingStart
                ? "Missing completed-second samples at recording start"
                : "Completed-second buffer overflow"
        )
    }

    static func makeDiscontinuityGap(
        sessionID: UUID,
        lastIntervalEnd: Date?,
        nextIntervalStart: Date,
        sessionStartedAt: Date,
        eventCount: UInt64,
        missingFrameCount: UInt64,
        discardedPartialFrameCount: UInt64
    ) -> MeasurementGap {
        let startedAt = lastIntervalEnd ?? sessionStartedAt
        let utcDelta = nextIntervalStart.timeIntervalSince(startedAt)
        let lostIntervals = utcDelta > 0 ? max(1, UInt64(ceil(utcDelta))) : 1
        let reason = String(
            format: "Audio input discontinuity (events %llu, missing frames %llu, discarded partial frames %llu, UTC delta %.6f s)",
            eventCount,
            missingFrameCount,
            discardedPartialFrameCount,
            utcDelta
        )
        return MeasurementGap(
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: nextIntervalStart,
            lostSecondIntervals: lostIntervals,
            reason: reason
        )
    }
}
