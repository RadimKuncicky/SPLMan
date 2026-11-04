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
        lock.lock()
        defer { lock.unlock() }
        guard queuedCount > 0, let sampleRate else { return [] }
        var frames: [AudioAnalysisSignalFrame] = []
        frames.reserveCapacity(queuedCount)
        while queuedCount > 0 {
            var samples = [Float](repeating: 0, count: frameCapacity)
            var referenceSamples: [Float]?
            let sourceOffset = readIndex * SpectrogramAnalyzer.maximumFrameCount
            samples.withUnsafeMutableBufferPointer { destination in
                queuedFrames.withUnsafeBufferPointer { source in
                    destination.baseAddress?.update(
                        from: source.baseAddress!.advanced(by: sourceOffset),
                        count: frameCapacity
                    )
                }
            }
            if capturesReference {
                var reference = [Float](repeating: 0, count: frameCapacity)
                reference.withUnsafeMutableBufferPointer { destination in
                    queuedReferenceFrames.withUnsafeBufferPointer { source in
                        destination.baseAddress?.update(
                            from: source.baseAddress!.advanced(by: sourceOffset),
                            count: frameCapacity
                        )
                    }
                }
                referenceSamples = reference
            }
            let capturedAtUptime = Double(
                AudioConvertHostTimeToNanos(queuedStartHostTimes[readIndex])
            ) / 1_000_000_000
            frames.append(AudioAnalysisSignalFrame(
                samples: samples,
                referenceSamples: referenceSamples,
                sampleRate: sampleRate,
                capturedAtUptime: capturedAtUptime
            ))
            readIndex = (readIndex + 1) % Self.queueCapacity
            queuedCount -= 1
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
    let snapshot: RawMeterSnapshot
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

    func offer(_ value: CompletedAudioSecond) {
        guard lock.try() else {
            pendingContentionDrops &+= 1
            return
        }
        droppedCount &+= pendingContentionDrops
        pendingContentionDrops = 0
        guard count < values.count else {
            droppedCount &+= 1
            lock.unlock()
            return
        }
        var adjustedSnapshot = value.snapshot
        adjustedSnapshot.lostSecondIntervals &+= droppedCount
        values[writeIndex] = CompletedAudioSecond(
            intervalEndUTC: value.intervalEndUTC,
            snapshot: adjustedSnapshot
        )
        writeIndex = (writeIndex + 1) % values.count
        count += 1
        lock.unlock()
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

final class AudioCaptureEngine {
    let latest = LatestSnapshotBox()
    private let completedSeconds = CompletedSecondQueue()
    private let health = AudioCaptureHealthBox()
    private let spectrogramSignalTap = SpectrogramSignalTap()
    private var audioUnit: AudioUnit?
    private var processor: SPLProcessor?
    private var capturesReference = false
    private var streamClockAnchorUTC: Date?
    private var streamClockAnchorHostTime: UInt64 = 0
    private var firstFrameUTC: Date?
    private var expectedNextSampleTime: Float64?
    private var pendingDiscontinuityMissingFrames: UInt64 = 0
    private var completedSecondTimestampBase: UInt64 = 0
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

            processor = SPLProcessor(sampleRate: sampleRate)
            capturesReference = referenceChannel != nil
            spectrogramSignalTap.configure(
                sampleRate: sampleRate,
                capturesReference: capturesReference
            )
            var callback = AURenderCallbackStruct(
                inputProc: Self.inputCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try check(AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ), L10n.text("registrace audio callbacku"))
            try check(AudioUnitInitialize(unit), L10n.text("inicializace vstupu"))
            completedSeconds.clear()
            health.configure(sampleRate: sampleRate)
            reportedClippedFrameCount = 0
            reportedDroppedSecondCount = 0
            streamClockAnchorUTC = Date()
            streamClockAnchorHostTime = AudioGetCurrentHostTime()
            firstFrameUTC = nil
            expectedNextSampleTime = nil
            pendingDiscontinuityMissingFrames = 0
            completedSecondTimestampBase = 0
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
        processor = nil
        capturesReference = false
        streamClockAnchorUTC = nil
        firstFrameUTC = nil
        expectedNextSampleTime = nil
        pendingDiscontinuityMissingFrames = 0
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
        let engine = Unmanaged<AudioCaptureEngine>.fromOpaque(context).takeUnretainedValue()
        guard let unit = engine.audioUnit, let processor = engine.processor else {
            return kAudio_ParamError
        }
        var bufferList = PairAudioBufferList(
            numberBuffers: engine.capturesReference ? 2 : 1,
            firstBuffer: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil),
            secondBuffer: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
        )
        let status = withUnsafeMutablePointer(to: &bufferList) { pointer in
            pointer.withMemoryRebound(to: AudioBufferList.self, capacity: 1) {
                AudioUnitRender(unit, flags, timestamp, 1, frameCount, $0)
            }
        }
        guard status == noErr else {
            engine.spectrogramSignalTap.discardPartialFrame()
            let discardedFrames = processor.invalidateTimeContinuity()
            engine.health.recordRenderError(
                status,
                discardedPartialFrames: discardedFrames
            )
            engine.prepareForNewTimeSegment(processor: processor)
            return status
        }
        guard let data = bufferList.firstBuffer.mData?.assumingMemoryBound(to: Float.self) else {
            engine.spectrogramSignalTap.discardPartialFrame()
            let discardedFrames = processor.invalidateTimeContinuity()
            engine.health.recordRenderError(
                kAudio_ParamError,
                discardedPartialFrames: discardedFrames
            )
            engine.prepareForNewTimeSegment(processor: processor)
            return kAudio_ParamError
        }
        if engine.updateStreamTiming(timestamp: timestamp.pointee, frameCount: frameCount) {
            engine.spectrogramSignalTap.discardPartialFrame()
            let discardedFrames = processor.invalidateTimeContinuity()
            engine.health.recordDropout(
                missingFrames: engine.pendingDiscontinuityMissingFrames,
                discardedPartialFrames: discardedFrames
            )
            engine.completedSecondTimestampBase = processor.currentCompletedSecondCount
        }
        let bufferStartHostTime = timestamp.pointee.mFlags.contains(.hostTimeValid)
            ? timestamp.pointee.mHostTime
            : nil
        engine.spectrogramSignalTap.append(
            data,
            referenceSamples: bufferList.secondBuffer.mData?.assumingMemoryBound(to: Float.self),
            count: Int(frameCount),
            bufferStartHostTime: bufferStartHostTime
        )
        if let snapshot = processor.process(data, count: Int(frameCount)) {
            engine.latest.offer(snapshot)
            engine.health.update(snapshot, dspDroppedSecondCount: processor.lostSecondIntervals)
        }
        while let snapshot = processor.popCompletedSecond() {
            guard let firstFrameUTC = engine.firstFrameUTC ?? engine.streamClockAnchorUTC else {
                engine.health.recordRenderError(kAudio_ParamError)
                continue
            }
            let intervalEndUTC = firstFrameUTC.addingTimeInterval(
                TimeInterval(snapshot.completedSecondCount - engine.completedSecondTimestampBase)
            )
            engine.completedSeconds.offer(CompletedAudioSecond(
                intervalEndUTC: intervalEndUTC,
                snapshot: snapshot
            ))
        }
        return noErr
    }

    private func updateStreamTiming(timestamp: AudioTimeStamp, frameCount: UInt32) -> Bool {
        if firstFrameUTC == nil { firstFrameUTC = utcDate(for: timestamp) }
        if firstFrameUTC == nil { firstFrameUTC = streamClockAnchorUTC }

        guard timestamp.mFlags.contains(.sampleTimeValid) else { return false }
        var discontinuity = false
        if let expectedNextSampleTime,
           abs(timestamp.mSampleTime - expectedNextSampleTime) > 1 {
            let skipped = timestamp.mSampleTime - expectedNextSampleTime
            let missingFrames = skipped > 0 ? UInt64(skipped.rounded()) : 0
            pendingDiscontinuityMissingFrames = missingFrames
            firstFrameUTC = utcDate(for: timestamp) ?? streamClockAnchorUTC
            discontinuity = true
        }
        expectedNextSampleTime = timestamp.mSampleTime + Float64(frameCount)
        return discontinuity
    }

    private func prepareForNewTimeSegment(processor: SPLProcessor) {
        firstFrameUTC = nil
        expectedNextSampleTime = nil
        pendingDiscontinuityMissingFrames = 0
        completedSecondTimestampBase = processor.currentCompletedSecondCount
    }

    private func utcDate(for timestamp: AudioTimeStamp) -> Date? {
        guard let anchorUTC = streamClockAnchorUTC,
              timestamp.mFlags.contains(.hostTimeValid) else { return nil }
        guard timestamp.mHostTime >= streamClockAnchorHostTime else { return anchorUTC }
        let nanoseconds = AudioConvertHostTimeToNanos(
            timestamp.mHostTime - streamClockAnchorHostTime
        )
        return anchorUTC.addingTimeInterval(Double(nanoseconds) / 1_000_000_000)
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
