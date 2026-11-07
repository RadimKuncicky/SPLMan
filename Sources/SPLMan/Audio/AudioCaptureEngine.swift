import AudioToolbox
import CoreAudio
import Foundation

final class LatestSnapshotBox {
    private let lock = NSLock()
    private var snapshot: RawMeterSnapshot?

    /// Audio callback never waits. A display update may be dropped if the UI
    /// is reading the previous one.
    func offer(_ value: RawMeterSnapshot) {
        guard lock.try() else { return }
        snapshot = value
        lock.unlock()
    }

    func take() -> RawMeterSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        let value = snapshot
        snapshot = nil
        return value
    }

    func clear() {
        lock.lock()
        snapshot = nil
        lock.unlock()
    }
}

/// Fixed-capacity handoff for optional spectrum analysis. The audio callback
/// uses `try()` and only copies samples; transforms happen on a utility queue.
private final class SpectrogramSignalTap {
    private static let queueCapacity = 4
    private let lock = NSLock()
    private var accumulation = [Float](
        repeating: 0,
        count: SpectrogramAnalyzer.maximumFrameCount
    )
    private var queuedFrames = [Float](
        repeating: 0,
        count: SpectrogramAnalyzer.maximumFrameCount * queueCapacity
    )
    private var referenceAccumulation = [Float](
        repeating: 0,
        count: SpectrogramAnalyzer.maximumFrameCount
    )
    private var queuedReferenceFrames = [Float](
        repeating: 0,
        count: SpectrogramAnalyzer.maximumFrameCount * queueCapacity
    )
    private var queuedStartHostTimes = [UInt64](repeating: 0, count: queueCapacity)
    // Consumer-owned staging, so `takeAll` only copies while holding `lock`
    // and the audio callback's `try()` is not blocked by allocations.
    private let consumerLock = NSLock()
    private var stagedFrames = [Float](
        repeating: 0,
        count: SpectrogramAnalyzer.maximumFrameCount * queueCapacity
    )
    private var stagedReferenceFrames = [Float](
        repeating: 0,
        count: SpectrogramAnalyzer.maximumFrameCount * queueCapacity
    )
    private var stagedStartHostTimes = [UInt64](repeating: 0, count: queueCapacity)
    private var frameCapacity = 0
    private var accumulatedCount = 0
    private var accumulationStartHostTime: UInt64 = 0
    private var readIndex = 0
    private var writeIndex = 0
    private var queuedCount = 0
    private var isEnabled = false
    private var capturesReference = false
    private var sampleRate: Double?
    private var pendingAppendDrop = false // audio-producer owned

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        isEnabled = enabled
        resetBuffers()
        lock.unlock()
    }

    func configure(sampleRate: Double, capturesReference: Bool) {
        lock.lock()
        self.sampleRate = sampleRate
        self.capturesReference = capturesReference
        frameCapacity = SpectrogramAnalyzer.frameCount(forSampleRate: sampleRate)
        resetBuffers()
        lock.unlock()
    }

    func append(
        _ samples: UnsafePointer<Float>,
        referenceSamples: UnsafePointer<Float>?,
        count: Int,
        bufferStartHostTime: UInt64?
    ) {
        guard lock.try() else {
            pendingAppendDrop = true
            return
        }
        defer { lock.unlock() }
        if pendingAppendDrop {
            accumulatedCount = 0
            accumulationStartHostTime = 0
            pendingAppendDrop = false
        }
        guard isEnabled,
              frameCapacity > 0,
              let sampleRate,
              let bufferStartHostTime,
              !capturesReference || referenceSamples != nil else {
            accumulatedCount = 0
            accumulationStartHostTime = 0
            return
        }

        var sourceOffset = 0
        while sourceOffset < count {
            if accumulatedCount == 0 {
                let offsetNanoseconds = UInt64(
                    Double(sourceOffset) / sampleRate * 1_000_000_000
                )
                accumulationStartHostTime = bufferStartHostTime
                    &+ AudioConvertNanosToHostTime(offsetNanoseconds)
            }
            let copyCount = min(frameCapacity - accumulatedCount, count - sourceOffset)
            accumulation.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress?.advanced(by: accumulatedCount).update(
                    from: samples.advanced(by: sourceOffset),
                    count: copyCount
                )
            }
            if let referenceSamples {
                referenceAccumulation.withUnsafeMutableBufferPointer { destination in
                    destination.baseAddress?.advanced(by: accumulatedCount).update(
                        from: referenceSamples.advanced(by: sourceOffset),
                        count: copyCount
                    )
                }
            }
            accumulatedCount += copyCount
            sourceOffset += copyCount
            if accumulatedCount == frameCapacity {
                if queuedCount == Self.queueCapacity {
                    readIndex = (readIndex + 1) % Self.queueCapacity
                    queuedCount -= 1
                }
                let destinationOffset = writeIndex * SpectrogramAnalyzer.maximumFrameCount
                queuedFrames.withUnsafeMutableBufferPointer { destination in
                    accumulation.withUnsafeBufferPointer { source in
                        destination.baseAddress?.advanced(by: destinationOffset).update(
                            from: source.baseAddress!,
                            count: frameCapacity
                        )
                    }
                }
                if capturesReference {
                    queuedReferenceFrames.withUnsafeMutableBufferPointer { destination in
                        referenceAccumulation.withUnsafeBufferPointer { source in
                            destination.baseAddress?.advanced(by: destinationOffset).update(
                                from: source.baseAddress!,
                                count: frameCapacity
                            )
                        }
                    }
                }
                queuedStartHostTimes[writeIndex] = accumulationStartHostTime
                writeIndex = (writeIndex + 1) % Self.queueCapacity
                queuedCount += 1
                accumulatedCount = 0
                accumulationStartHostTime = 0
            }
        }
    }

    func takeAll() -> [AudioAnalysisSignalFrame] {
        consumerLock.lock()
        defer { consumerLock.unlock() }

        // Phase 1: memcpy only, no allocation, while the producer is locked out.
        lock.lock()
        guard queuedCount > 0, let sampleRate else {
            lock.unlock()
            return []
        }
        let frameCount = queuedCount
        let samplesPerFrame = frameCapacity
        let hasReference = capturesReference
        let frameStride = SpectrogramAnalyzer.maximumFrameCount
        for slot in 0..<frameCount {
            let sourceOffset = readIndex * frameStride
            let destinationOffset = slot * frameStride
            stagedFrames.withUnsafeMutableBufferPointer { destination in
                queuedFrames.withUnsafeBufferPointer { source in
                    destination.baseAddress!.advanced(by: destinationOffset).update(
                        from: source.baseAddress!.advanced(by: sourceOffset),
                        count: samplesPerFrame
                    )
                }
            }
            if hasReference {
                stagedReferenceFrames.withUnsafeMutableBufferPointer { destination in
                    queuedReferenceFrames.withUnsafeBufferPointer { source in
                        destination.baseAddress!.advanced(by: destinationOffset).update(
                            from: source.baseAddress!.advanced(by: sourceOffset),
                            count: samplesPerFrame
                        )
                    }
                }
            }
            stagedStartHostTimes[slot] = queuedStartHostTimes[readIndex]
            readIndex = (readIndex + 1) % Self.queueCapacity
            queuedCount -= 1
        }
        lock.unlock()

        // Phase 2: build the output arrays without blocking the audio callback.
        var frames: [AudioAnalysisSignalFrame] = []
        frames.reserveCapacity(frameCount)
        for slot in 0..<frameCount {
            let range = (slot * frameStride)..<(slot * frameStride + samplesPerFrame)
            frames.append(AudioAnalysisSignalFrame(
                samples: Array(stagedFrames[range]),
                referenceSamples: hasReference ? Array(stagedReferenceFrames[range]) : nil,
                sampleRate: sampleRate,
                capturedAtUptime: Double(
                    AudioConvertHostTimeToNanos(stagedStartHostTimes[slot])
                ) / 1_000_000_000
            ))
        }
        return frames
    }

    func discardPartialFrame() {
        guard lock.try() else {
            pendingAppendDrop = true
            return
        }
        accumulatedCount = 0
        accumulationStartHostTime = 0
        lock.unlock()
    }

    func clear() {
        lock.lock()
        resetBuffers()
        frameCapacity = 0
        sampleRate = nil
        capturesReference = false
        lock.unlock()
    }

    private func resetBuffers() {
        accumulatedCount = 0
        accumulationStartHostTime = 0
        readIndex = 0
        writeIndex = 0
        queuedCount = 0
    }
}

struct AudioAnalysisSignalFrame {
    let samples: [Float]
    let referenceSamples: [Float]?
    let sampleRate: Double
    let capturedAtUptime: TimeInterval
}

private struct PairAudioBufferList {
    var numberBuffers: UInt32
    var firstBuffer: AudioBuffer
    var secondBuffer: AudioBuffer
}

struct CompletedAudioSecond: Equatable {
    let intervalEndUTC: Date
    var snapshot: RawMeterSnapshot
    /// Input discontinuities (dropouts, render errors) that occurred after the
    /// previously delivered interval and before this one began. Travelling
    /// with the interval keeps gap rows in stream order.
    var precedingDiscontinuityEvents: UInt64 = 0
    var precedingMissingFrames: UInt64 = 0
    var precedingDiscardedPartialFrames: UInt64 = 0
}

struct AudioCaptureHealth: Equatable {
    let sampleRate: Double?
    let processedFrameCount: UInt64
    /// Counts since the preceding `takeHealthEvents()` call.
    let clippedFrameCount: UInt64
    let renderErrorCount: UInt64
    let audioDropoutCount: UInt64
    let missingFrameCount: UInt64
    let discardedPartialFrameCount: UInt64
    let droppedSecondIntervalCount: UInt64
    let lastRenderStatus: OSStatus?
}

/// A bounded producer/consumer queue. The audio callback uses `try()` and
/// never waits for the main-thread consumer. Contention and capacity loss are
/// counted and attached to the next accepted interval.
private final class CompletedSecondQueue {
    private static let capacity = 120
    private let lock = NSLock()
    private var values = Array<CompletedAudioSecond?>(repeating: nil, count: capacity)
    private var readIndex = 0
    private var writeIndex = 0
    private var count = 0
    private var droppedCount: UInt64 = 0
    private var pendingContentionDrops: UInt64 = 0 // audio-producer owned

    /// Returns `false` when the interval was dropped.
    @discardableResult
    func offer(_ value: CompletedAudioSecond) -> Bool {
        guard lock.try() else {
            pendingContentionDrops &+= 1
            return false
        }
        droppedCount &+= pendingContentionDrops
        pendingContentionDrops = 0
        guard count < values.count else {
            droppedCount &+= 1
            lock.unlock()
            return false
        }
        var adjusted = value
        adjusted.snapshot.lostSecondIntervals &+= droppedCount
        values[writeIndex] = adjusted
        writeIndex = (writeIndex + 1) % values.count
        count += 1
        lock.unlock()
        return true
    }

    func take() -> CompletedAudioSecond? {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return nil }
        let value = values[readIndex]
        values[readIndex] = nil
        readIndex = (readIndex + 1) % values.count
        count -= 1
        return value
    }

    func cumulativeDroppedCount() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return droppedCount
    }

    func flushAfterProducerStopped() {
        lock.lock()
        droppedCount &+= pendingContentionDrops
        pendingContentionDrops = 0
        lock.unlock()
    }

    func clear() {
        lock.lock()
        values = Array(repeating: nil, count: Self.capacity)
        readIndex = 0
        writeIndex = 0
        count = 0
        droppedCount = 0
        pendingContentionDrops = 0
        lock.unlock()
    }
}

/// State of the stream after the last interval handed to the consumer queue.
/// A consumer that has drained the queue uses it to log what happened after
/// its last interval without double-counting events attached to intervals.
struct AudioStreamTail: Equatable {
    /// Completed-second count of the last interval accepted by the queue.
    let lastDeliveredCompletedSecondCount: UInt64?
    /// Lifetime completed-second count of the DSP, delivered or dropped.
    let completedSecondCount: UInt64
    /// Discontinuities not yet attached to a delivered interval.
    let pendingDiscontinuityEvents: UInt64
    let pendingMissingFrames: UInt64
    let pendingDiscardedPartialFrames: UInt64
}

/// Published at the end of every callback with `try()`. A missed publication
/// leaves the value at most one callback old, never ahead of the queue.
private final class AudioStreamTailBox {
    private let lock = NSLock()
    private var value: AudioStreamTail?

    func publish(_ tail: AudioStreamTail) {
        guard lock.try() else { return }
        value = tail
        lock.unlock()
    }

    func read() -> AudioStreamTail? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func clear() {
        lock.lock()
        value = nil
        lock.unlock()
    }
}

private final class AudioCaptureHealthBox {
    private let lock = NSLock()
    private var sampleRate: Double?
    private var processedFrameCount: UInt64 = 0
    private var clippedFrameCount: UInt64 = 0
    private var dspDroppedSecondCount: UInt64 = 0
    private var renderErrorCount: UInt64 = 0
    private var audioDropoutCount: UInt64 = 0
    private var missingFrameCount: UInt64 = 0
    private var discardedPartialFrameCount: UInt64 = 0
    private var lastRenderStatus: OSStatus?
    private var pendingRenderErrors: UInt64 = 0 // audio-producer owned
    private var pendingDropouts: UInt64 = 0 // audio-producer owned
    private var pendingMissingFrames: UInt64 = 0 // audio-producer owned
    private var pendingDiscardedPartialFrames: UInt64 = 0 // audio-producer owned
    private var pendingRenderStatus: OSStatus?

    func configure(sampleRate: Double) {
        lock.lock()
        self.sampleRate = sampleRate
        processedFrameCount = 0
        clippedFrameCount = 0
        dspDroppedSecondCount = 0
        renderErrorCount = 0
        audioDropoutCount = 0
        missingFrameCount = 0
        discardedPartialFrameCount = 0
        lastRenderStatus = nil
        pendingRenderErrors = 0
        pendingDropouts = 0
        pendingMissingFrames = 0
        pendingDiscardedPartialFrames = 0
        pendingRenderStatus = nil
        lock.unlock()
    }

    func update(_ snapshot: RawMeterSnapshot, dspDroppedSecondCount: UInt64) {
        guard lock.try() else { return }
        mergePendingEvents()
        processedFrameCount = snapshot.processedFrameCount
        clippedFrameCount = snapshot.clippedFrameCount
        self.dspDroppedSecondCount = dspDroppedSecondCount
        lock.unlock()
    }

    func recordRenderError(_ status: OSStatus, discardedPartialFrames: UInt64 = 0) {
        guard lock.try() else {
            pendingRenderErrors &+= 1
            pendingRenderStatus = status
            pendingDiscardedPartialFrames &+= discardedPartialFrames
            return
        }
        mergePendingEvents()
        renderErrorCount &+= 1
        lastRenderStatus = status
        discardedPartialFrameCount &+= discardedPartialFrames
        lock.unlock()
    }

    func recordDropout(missingFrames: UInt64, discardedPartialFrames: UInt64) {
        guard lock.try() else {
            pendingDropouts &+= 1
            pendingMissingFrames &+= missingFrames
            pendingDiscardedPartialFrames &+= discardedPartialFrames
            return
        }
        mergePendingEvents()
        audioDropoutCount &+= 1
        missingFrameCount &+= missingFrames
        discardedPartialFrameCount &+= discardedPartialFrames
        lock.unlock()
    }

    func takeEventState() -> (
        sampleRate: Double?,
        processedFrames: UInt64,
        clippedFrames: UInt64,
        dspDroppedSeconds: UInt64,
        renderErrors: UInt64,
        dropouts: UInt64,
        missingFrames: UInt64,
        discardedPartialFrames: UInt64,
        renderStatus: OSStatus?
    ) {
        lock.lock()
        let state = (
            sampleRate: sampleRate,
            processedFrames: processedFrameCount,
            clippedFrames: clippedFrameCount,
            dspDroppedSeconds: dspDroppedSecondCount,
            renderErrors: renderErrorCount,
            dropouts: audioDropoutCount,
            missingFrames: missingFrameCount,
            discardedPartialFrames: discardedPartialFrameCount,
            renderStatus: lastRenderStatus
        )
        renderErrorCount = 0
        audioDropoutCount = 0
        missingFrameCount = 0
        discardedPartialFrameCount = 0
        lastRenderStatus = nil
        lock.unlock()
        return state
    }

    func flushAfterProducerStopped() {
        lock.lock()
        mergePendingEvents()
        lock.unlock()
    }

    private func mergePendingEvents() {
        renderErrorCount &+= pendingRenderErrors
        audioDropoutCount &+= pendingDropouts
        missingFrameCount &+= pendingMissingFrames
        discardedPartialFrameCount &+= pendingDiscardedPartialFrames
        if let pendingRenderStatus { lastRenderStatus = pendingRenderStatus }
        pendingRenderErrors = 0
        pendingDropouts = 0
        pendingMissingFrames = 0
        pendingDiscardedPartialFrames = 0
        pendingRenderStatus = nil
    }
}

enum AudioCaptureError: LocalizedError {
    case deviceMissing
    case invalidChannel
    case componentUnavailable
    case unsupportedSampleRate(Double)
    case osStatus(OSStatus, operation: String)

    var errorDescription: String? {
        switch self {
        case .deviceMissing: L10n.text("Vybrané zvukové zařízení není dostupné.")
        case .invalidChannel: L10n.text("Vybraný kanál na zařízení neexistuje.")
        case .componentUnavailable: L10n.text("Core Audio vstup není dostupný.")
        case let .unsupportedSampleRate(rate):
            L10n.format("Vzorkovací frekvence %.0f Hz není podporována.", rate)
        case let .osStatus(status, operation): L10n.format("Core Audio: %@ (%d).", operation, status)
        }
    }
}

/// State used by the real-time callback. One instance exists per started
/// stream and is retained by the audio unit's refCon until the unit has been
/// disposed, so the main thread never mutates anything the callback reads.
private final class AudioRenderContext {
    let unit: AudioUnit
    let processor: SPLProcessor
    let sampleRate: Double
    let capturesReference: Bool
    let latest: LatestSnapshotBox
    let completedSeconds: CompletedSecondQueue
    let health: AudioCaptureHealthBox
    let spectrogramSignalTap: SpectrogramSignalTap
    let streamTail: AudioStreamTailBox

    // Audio-thread owned.
    private var expectedNextSampleTime: Float64?
    private var pendingDiscontinuityEvents: UInt64 = 0
    private var pendingMissingFrames: UInt64 = 0
    private var pendingDiscardedPartialFrames: UInt64 = 0
    private var lastDeliveredCompletedSecondCount: UInt64?

    init(
        unit: AudioUnit,
        processor: SPLProcessor,
        sampleRate: Double,
        capturesReference: Bool,
        latest: LatestSnapshotBox,
        completedSeconds: CompletedSecondQueue,
        health: AudioCaptureHealthBox,
        spectrogramSignalTap: SpectrogramSignalTap,
        streamTail: AudioStreamTailBox
    ) {
        self.unit = unit
        self.processor = processor
        self.sampleRate = sampleRate
        self.capturesReference = capturesReference
        self.latest = latest
        self.completedSeconds = completedSeconds
        self.health = health
        self.spectrogramSignalTap = spectrogramSignalTap
        self.streamTail = streamTail
    }

    private func publishStreamTail() {
        streamTail.publish(AudioStreamTail(
            lastDeliveredCompletedSecondCount: lastDeliveredCompletedSecondCount,
            completedSecondCount: processor.currentCompletedSecondCount,
            pendingDiscontinuityEvents: pendingDiscontinuityEvents,
            pendingMissingFrames: pendingMissingFrames,
            pendingDiscardedPartialFrames: pendingDiscardedPartialFrames
        ))
    }

    func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: UInt32
    ) -> OSStatus {
        var bufferList = PairAudioBufferList(
            numberBuffers: capturesReference ? 2 : 1,
            firstBuffer: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil),
            secondBuffer: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
        )
        let status = withUnsafeMutablePointer(to: &bufferList) { pointer in
            pointer.withMemoryRebound(to: AudioBufferList.self, capacity: 1) {
                AudioUnitRender(unit, flags, timestamp, 1, frameCount, $0)
            }
        }
        guard status == noErr else {
            invalidateAfterRenderFailure(status)
            return status
        }
        guard let data = bufferList.firstBuffer.mData?.assumingMemoryBound(to: Float.self) else {
            invalidateAfterRenderFailure(kAudio_ParamError)
            return kAudio_ParamError
        }
        let bufferStartDate = bufferStartUTC(timestamp: timestamp.pointee, frameCount: frameCount)
        if let missingFrames = detectDiscontinuity(
            timestamp: timestamp.pointee,
            frameCount: frameCount
        ) {
            spectrogramSignalTap.discardPartialFrame()
            let discardedFrames = processor.invalidateTimeContinuity()
            health.recordDropout(
                missingFrames: missingFrames,
                discardedPartialFrames: discardedFrames
            )
            pendingDiscontinuityEvents &+= 1
            pendingMissingFrames &+= missingFrames
            pendingDiscardedPartialFrames &+= discardedFrames
        }
        let bufferStartHostTime = timestamp.pointee.mFlags.contains(.hostTimeValid)
            ? timestamp.pointee.mHostTime
            : nil
        spectrogramSignalTap.append(
            data,
            referenceSamples: bufferList.secondBuffer.mData?.assumingMemoryBound(to: Float.self),
            count: Int(frameCount),
            bufferStartHostTime: bufferStartHostTime
        )
        let framesBeforeBuffer = processor.currentProcessedFrameCount
        if let snapshot = processor.process(data, count: Int(frameCount)) {
            latest.offer(snapshot)
            health.update(snapshot, dspDroppedSecondCount: processor.lostSecondIntervals)
        }
        while let snapshot = processor.popCompletedSecond() {
            // The interval ends at a known frame of this buffer; the buffer
            // start is placed on the UTC wall clock, so audio-clock drift
            // does not accumulate into the logged timestamps.
            let endOffsetFrames = snapshot.processedFrameCount &- framesBeforeBuffer
            let intervalEndUTC = bufferStartDate.addingTimeInterval(
                Double(endOffsetFrames) / sampleRate
            )
            let delivered = completedSeconds.offer(CompletedAudioSecond(
                intervalEndUTC: intervalEndUTC,
                snapshot: snapshot,
                precedingDiscontinuityEvents: pendingDiscontinuityEvents,
                precedingMissingFrames: pendingMissingFrames,
                precedingDiscardedPartialFrames: pendingDiscardedPartialFrames
            ))
            if delivered {
                pendingDiscontinuityEvents = 0
                pendingMissingFrames = 0
                pendingDiscardedPartialFrames = 0
                lastDeliveredCompletedSecondCount = snapshot.completedSecondCount
            }
        }
        publishStreamTail()
        return noErr
    }

    private func invalidateAfterRenderFailure(_ status: OSStatus) {
        spectrogramSignalTap.discardPartialFrame()
        let discardedFrames = processor.invalidateTimeContinuity()
        health.recordRenderError(status, discardedPartialFrames: discardedFrames)
        pendingDiscontinuityEvents &+= 1
        pendingDiscardedPartialFrames &+= discardedFrames
        expectedNextSampleTime = nil
        publishStreamTail()
    }

    /// Returns the number of skipped frames when the sample time does not
    /// continue the previous buffer.
    private func detectDiscontinuity(timestamp: AudioTimeStamp, frameCount: UInt32) -> UInt64? {
        guard timestamp.mFlags.contains(.sampleTimeValid) else { return nil }
        var missingFrames: UInt64?
        if let expectedNextSampleTime,
           abs(timestamp.mSampleTime - expectedNextSampleTime) > 1 {
            let skipped = timestamp.mSampleTime - expectedNextSampleTime
            missingFrames = skipped > 0 ? UInt64(skipped.rounded()) : 0
        }
        expectedNextSampleTime = timestamp.mSampleTime + Float64(frameCount)
        return missingFrames
    }

    private func bufferStartUTC(timestamp: AudioTimeStamp, frameCount: UInt32) -> Date {
        let now = Date()
        let nowHostTime = AudioGetCurrentHostTime()
        if timestamp.mFlags.contains(.hostTimeValid), timestamp.mHostTime <= nowHostTime {
            let ageNanoseconds = AudioConvertHostTimeToNanos(nowHostTime - timestamp.mHostTime)
            return now.addingTimeInterval(-Double(ageNanoseconds) / 1_000_000_000)
        }
        return now.addingTimeInterval(-Double(frameCount) / sampleRate)
    }
}

final class AudioCaptureEngine {
    let latest = LatestSnapshotBox()
    private let completedSeconds = CompletedSecondQueue()
    private let health = AudioCaptureHealthBox()
    private let spectrogramSignalTap = SpectrogramSignalTap()
    private let streamTail = AudioStreamTailBox()
    private var audioUnit: AudioUnit?
    private var renderContext: Unmanaged<AudioRenderContext>?
    private var reportedClippedFrameCount: UInt64 = 0
    private var reportedDroppedSecondCount: UInt64 = 0

    deinit { stop() }

    func start(selection: InputSelection, referenceChannel: Int? = nil) throws {
        stop()
        guard let device = AudioDeviceRepository.device(uid: selection.deviceUID) else {
            throw AudioCaptureError.deviceMissing
        }
        guard selection.channel >= 0, selection.channel < device.inputChannelCount else {
            throw AudioCaptureError.invalidChannel
        }
        if let referenceChannel,
           (referenceChannel < 0
               || referenceChannel >= device.inputChannelCount
               || referenceChannel == selection.channel) {
            throw AudioCaptureError.invalidChannel
        }

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioCaptureError.componentUnavailable
        }
        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &unit), L10n.text("vytvoření vstupu"))
        guard let unit else { throw AudioCaptureError.componentUnavailable }
        audioUnit = unit

        do {
            var enabled: UInt32 = 1
            var disabled: UInt32 = 0
            try check(AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                &enabled, UInt32(MemoryLayout<UInt32>.size)
            ), L10n.text("zapnutí vstupu"))
            try check(AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                &disabled, UInt32(MemoryLayout<UInt32>.size)
            ), L10n.text("vypnutí výstupu"))

            var deviceID = device.id
            try check(AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
            ), L10n.text("volba zařízení"))

            let sampleRate = try nominalSampleRate(deviceID: deviceID)
            guard SPLProcessor.isValidSampleRate(sampleRate) else {
                throw AudioCaptureError.unsupportedSampleRate(sampleRate)
            }
            let outputChannelCount: UInt32 = referenceChannel == nil ? 1 : 2
            var format = AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: outputChannelCount,
                mBitsPerChannel: 32,
                mReserved: 0
            )
            try check(AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ), L10n.text("formát vstupu"))

            var channelMap = referenceChannel.map {
                [Int32(selection.channel), Int32($0)]
            } ?? [Int32(selection.channel)]
            try channelMap.withUnsafeMutableBufferPointer { map in
                try check(AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1,
                    map.baseAddress, UInt32(map.count * MemoryLayout<Int32>.size)
                ), L10n.text("volba kanálu"))
            }

            var shouldAllocate: UInt32 = 1
            try check(AudioUnitSetProperty(
                unit, kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Output, 1,
                &shouldAllocate, UInt32(MemoryLayout<UInt32>.size)
            ), L10n.text("alokace audio bufferu"))

            let capturesReference = referenceChannel != nil
            spectrogramSignalTap.configure(
                sampleRate: sampleRate,
                capturesReference: capturesReference
            )
            let context = Unmanaged.passRetained(AudioRenderContext(
                unit: unit,
                processor: SPLProcessor(sampleRate: sampleRate),
                sampleRate: sampleRate,
                capturesReference: capturesReference,
                latest: latest,
                completedSeconds: completedSeconds,
                health: health,
                spectrogramSignalTap: spectrogramSignalTap,
                streamTail: streamTail
            ))
            renderContext = context
            var callback = AURenderCallbackStruct(
                inputProc: Self.inputCallback,
                inputProcRefCon: context.toOpaque()
            )
            try check(AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ), L10n.text("registrace audio callbacku"))
            try check(AudioUnitInitialize(unit), L10n.text("inicializace vstupu"))
            completedSeconds.clear()
            streamTail.clear()
            health.configure(sampleRate: sampleRate)
            reportedClippedFrameCount = 0
            reportedDroppedSecondCount = 0
            try check(AudioOutputUnitStart(unit), L10n.text("spuštění vstupu"))
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            completedSeconds.flushAfterProducerStopped()
            health.flushAfterProducerStopped()
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        audioUnit = nil
        // Released only after the unit is disposed and can no longer call back.
        renderContext?.release()
        renderContext = nil
        latest.clear()
        spectrogramSignalTap.clear()
    }

    func setSpectrogramCaptureEnabled(_ enabled: Bool) {
        spectrogramSignalTap.setEnabled(enabled)
    }

    func takeAnalysisSignalFrames() -> [AudioAnalysisSignalFrame] {
        spectrogramSignalTap.takeAll()
    }

    func takeCompletedSecond() -> CompletedAudioSecond? {
        completedSeconds.take()
    }

    /// Read this before draining `takeCompletedSecond()`: every interval it
    /// counts is then either drained or was dropped.
    func currentStreamTail() -> AudioStreamTail? {
        streamTail.read()
    }

    /// Returns event deltas plus cumulative frame count and current sample rate.
    func takeHealthEvents() -> AudioCaptureHealth {
        let state = health.takeEventState()
        let allDroppedSeconds = state.dspDroppedSeconds
            &+ completedSeconds.cumulativeDroppedCount()
        let clippedDelta = state.clippedFrames &- min(
            state.clippedFrames,
            reportedClippedFrameCount
        )
        let droppedDelta = allDroppedSeconds &- min(
            allDroppedSeconds,
            reportedDroppedSecondCount
        )
        reportedClippedFrameCount = state.clippedFrames
        reportedDroppedSecondCount = allDroppedSeconds
        return AudioCaptureHealth(
            sampleRate: state.sampleRate,
            processedFrameCount: state.processedFrames,
            clippedFrameCount: clippedDelta,
            renderErrorCount: state.renderErrors,
            audioDropoutCount: state.dropouts,
            missingFrameCount: state.missingFrames,
            discardedPartialFrameCount: state.discardedPartialFrames,
            droppedSecondIntervalCount: droppedDelta,
            lastRenderStatus: state.renderStatus
        )
    }

    private static let inputCallback: AURenderCallback = {
        context, flags, timestamp, _, frameCount, _ in
        Unmanaged<AudioRenderContext>.fromOpaque(context)
            .takeUnretainedValue()
            .render(flags: flags, timestamp: timestamp, frameCount: frameCount)
    }

    private func nominalSampleRate(deviceID: AudioDeviceID) throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        try check(AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &sampleRate
        ), L10n.text("zjištění vzorkovací frekvence"))
        return sampleRate
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw AudioCaptureError.osStatus(status, operation: operation)
        }
    }
}
