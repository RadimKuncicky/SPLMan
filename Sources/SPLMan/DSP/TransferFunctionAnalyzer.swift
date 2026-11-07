import Foundation

struct TransferSignalFrame {
    let measurement: [Float]
    let reference: [Float]
    let sampleRate: Double
    let capturedAtUptime: TimeInterval
}

enum TransferFunctionValidity: Equatable {
    case valid
    case waitingForSignal
    case invalidReference
}

struct TransferFunctionPoint: Equatable {
    let frequency: Double
    let magnitudeDB: Double
}

struct TransferFunctionCurve: Equatable {
    let points: [TransferFunctionPoint]
    let frequencyScale: SpectrogramFrequencyScale
    let delaySeconds: Double
    let displayLowerDB: Double
    let displayUpperDB: Double
    let capturedAtUptime: TimeInterval
}

struct TransferFunctionAnalysis: Equatable {
    let validity: TransferFunctionValidity
    let curve: TransferFunctionCurve?
}

enum TransferFunctionDSP {
    static let minimumReferenceRMSDBFS = -70.0
    static let cyclesInWindow = 6.0
    static let minimumWindowDuration = 0.004
    static let automaticGainFrequencyRange = 500.0...4_000.0
    static let automaticGainSmoothingTimeConstant: TimeInterval = 1
    private static let preferredMaximumWindowDuration = 0.120
    private static let preferredMaximumDelayDuration = 0.100
    private static let preWindowDuration = 0.002
    private static let delayPreferenceRadius: TimeInterval = 0.001
    private static let minimumPreferredPeakRatio = 0.5
    private static let minimumDelayPeakMagnitude = 0.04
    private static let minimumNormalizedCorrelation = 0.05

    static func analysisFrameCount(sampleRate: Double) -> Int {
        guard sampleRate > 0 else { return SpectrogramAnalyzer.fftSize }
        let requiredDuration = max(
            preferredMaximumDelayDuration + preferredMaximumWindowDuration
                + preWindowDuration,
            2 * (preferredMaximumWindowDuration + preWindowDuration)
        )
        let requiredSamples = max(
            SpectrogramAnalyzer.fftSize,
            Int(ceil(sampleRate * requiredDuration))
        )
        var frameCount = 1
        while frameCount < requiredSamples { frameCount <<= 1 }
        return frameCount
    }

    static func windowDuration(
        for frequency: Double,
        sampleRate: Double,
        frameCount: Int = SpectrogramAnalyzer.fftSize
    ) -> TimeInterval {
        guard frequency > 0, sampleRate > 0, frameCount > 2 else { return 0 }
        let requestedDuration = min(
            preferredMaximumWindowDuration,
            max(minimumWindowDuration, cyclesInWindow / frequency)
        )
        let maximumRepresentableDuration = Double(frameCount / 2 - 1) / sampleRate
        return min(requestedDuration, maximumRepresentableDuration)
    }

    static func maximumDetectableDelay(
        sampleRate: Double,
        frameCount: Int = SpectrogramAnalyzer.fftSize
    ) -> TimeInterval {
        guard sampleRate > 0, frameCount > 2 else { return 0 }
        return min(
            preferredMaximumDelayDuration,
            Double(frameCount / 2 - 1) / sampleRate
        )
    }

    static func framesAreContinuous(
        expectedNextUptime: TimeInterval,
        nextUptime: TimeInterval,
        sampleRate: Double
    ) -> Bool {
        guard sampleRate > 0 else { return false }
        return abs(expectedNextUptime - nextUptime)
            <= max(2 / sampleRate, 0.000_001)
    }

    static func analyze(
        frame: TransferSignalFrame,
        range: SpectrogramFrequencyRange,
        preferredDelaySamples: Double? = nil
    ) -> TransferFunctionAnalysis {
        let count = frame.measurement.count
        guard count >= SpectrogramAnalyzer.fftSize,
              count.nonzeroBitCount == 1,
              frame.reference.count == count,
              frame.sampleRate > 0,
              let scale = SpectrogramFrequencyScale(
                  sampleRate: frame.sampleRate,
                  frameCount: count,
                  range: range
              ) else {
            return TransferFunctionAnalysis(validity: .waitingForSignal, curve: nil)
        }

        var referenceEnergy = 0.0
        for sample in frame.reference {
            let value = Double(sample)
            referenceEnergy += value * value
        }
        let referenceRMS = sqrt(referenceEnergy / Double(count))
        let referenceRMSDBFS = 20 * log10(max(referenceRMS, 1e-20))
        guard referenceRMSDBFS >= minimumReferenceRMSDBFS else {
            return TransferFunctionAnalysis(validity: .invalidReference, curve: nil)
        }

        var referenceReal = [Double](repeating: 0, count: count)
        var referenceImaginary = [Double](repeating: 0, count: count)
        var measurementReal = [Double](repeating: 0, count: count)
        var measurementImaginary = [Double](repeating: 0, count: count)
        let denominator = Double(count - 1)
        for index in 0..<count {
            let window = 0.5 - 0.5 * cos(2 * .pi * Double(index) / denominator)
            referenceReal[index] = Double(frame.reference[index]) * window
            measurementReal[index] = Double(frame.measurement[index]) * window
        }
        fft(real: &referenceReal, imaginary: &referenceImaginary, inverse: false)
        fft(real: &measurementReal, imaginary: &measurementImaginary, inverse: false)

        var correlationReal = [Double](repeating: 0, count: count)
        var correlationImaginary = [Double](repeating: 0, count: count)
        for bin in 0..<count {
            let real = measurementReal[bin] * referenceReal[bin]
                + measurementImaginary[bin] * referenceImaginary[bin]
            let imaginary = measurementImaginary[bin] * referenceReal[bin]
                - measurementReal[bin] * referenceImaginary[bin]
            let magnitude = hypot(real, imaginary)
            if magnitude > 1e-20 {
                correlationReal[bin] = real / magnitude
                correlationImaginary[bin] = imaginary / magnitude
            }
        }
        fft(real: &correlationReal, imaginary: &correlationImaginary, inverse: true)

        let maximumLag = Int((maximumDetectableDelay(
            sampleRate: frame.sampleRate,
            frameCount: count
        ) * frame.sampleRate).rounded(.down))
        var peakIndex = 0
        var peakMagnitude = 0.0
        var selectedNormalizedCorrelation: Double?
        if maximumLag > 0 {
            for index in 0...maximumLag {
                let magnitude = abs(correlationReal[index])
                if magnitude > peakMagnitude {
                    peakMagnitude = magnitude
                    peakIndex = index
                }
            }
            for index in (count - maximumLag)..<count {
                let magnitude = abs(correlationReal[index])
                if magnitude > peakMagnitude {
                    peakMagnitude = magnitude
                    peakIndex = index
                }
            }
        }
        if let preferredDelaySamples,
           preferredDelaySamples.isFinite {
            let preferenceRadius = max(
                2,
                Int((frame.sampleRate * delayPreferenceRadius).rounded())
            )
            let preferredCenter = Int(preferredDelaySamples.rounded())
            let lowerPreferredLag = max(-maximumLag, preferredCenter - preferenceRadius)
            let upperPreferredLag = min(maximumLag, preferredCenter + preferenceRadius)
            var preferredPeakIndex: Int?
            var preferredPeakMagnitude = 0.0
            if lowerPreferredLag <= upperPreferredLag {
                for lag in lowerPreferredLag...upperPreferredLag {
                    let index = lag >= 0 ? lag : count + lag
                    let magnitude = abs(correlationReal[index])
                    if magnitude > preferredPeakMagnitude {
                        preferredPeakMagnitude = magnitude
                        preferredPeakIndex = index
                    }
                }
            }
            if let preferredPeakIndex,
               preferredPeakMagnitude >= minimumDelayPeakMagnitude,
               preferredPeakMagnitude >= minimumPreferredPeakRatio * peakMagnitude {
                let preferredDelay = preferredPeakIndex <= maximumLag
                    ? preferredPeakIndex
                    : preferredPeakIndex - count
                let preferredCorrelation = normalizedCorrelation(
                    measurement: frame.measurement,
                    reference: frame.reference,
                    delay: preferredDelay
                )
                if preferredCorrelation >= minimumNormalizedCorrelation {
                    peakIndex = preferredPeakIndex
                    peakMagnitude = preferredPeakMagnitude
                    selectedNormalizedCorrelation = preferredCorrelation
                }
            }
        }
        guard peakMagnitude >= minimumDelayPeakMagnitude else {
            return TransferFunctionAnalysis(validity: .invalidReference, curve: nil)
        }

        let detectedDelay = peakIndex <= maximumLag
            ? Double(peakIndex)
            : Double(peakIndex - count)
        let delayCorrelation = selectedNormalizedCorrelation ?? normalizedCorrelation(
            measurement: frame.measurement,
            reference: frame.reference,
            delay: Int(detectedDelay.rounded())
        )
        guard delayCorrelation >= minimumNormalizedCorrelation else {
            return TransferFunctionAnalysis(validity: .invalidReference, curve: nil)
        }
        let delaySamples = detectedDelay
        let integerDelay = Int(delaySamples.rounded())
        let measurementStart = max(0, integerDelay)
        let referenceStart = max(0, -integerDelay)
        let alignedCount = min(
            count - measurementStart,
            count - referenceStart
        )
        guard alignedCount >= SpectrogramAnalyzer.fftSize else {
            return TransferFunctionAnalysis(validity: .invalidReference, curve: nil)
        }

        for index in 0..<count {
            referenceReal[index] = 0
            referenceImaginary[index] = 0
            measurementReal[index] = 0
            measurementImaginary[index] = 0
        }
        let alignedWindowDenominator = Double(alignedCount - 1)
        for index in 0..<alignedCount {
            let window = 0.5
                - 0.5 * cos(2 * .pi * Double(index) / alignedWindowDenominator)
            referenceReal[index] = Double(frame.reference[referenceStart + index]) * window
            measurementReal[index] = Double(frame.measurement[measurementStart + index]) * window
        }
        fft(real: &referenceReal, imaginary: &referenceImaginary, inverse: false)
        fft(real: &measurementReal, imaginary: &measurementImaginary, inverse: false)

        var maximumReferencePower = 0.0
        for bin in 1..<(count / 2) {
            maximumReferencePower = max(
                maximumReferencePower,
                referenceReal[bin] * referenceReal[bin]
                    + referenceImaginary[bin] * referenceImaginary[bin]
            )
        }
        guard maximumReferencePower > 1e-16 else {
            return TransferFunctionAnalysis(validity: .invalidReference, curve: nil)
        }

        let regularization = maximumReferencePower * 1e-8
        let usableReferencePower = maximumReferencePower * 1e-5
        var transferReal = [Double](repeating: 0, count: count)
        var transferImaginary = [Double](repeating: 0, count: count)
        var validBins = [Bool](repeating: false, count: count / 2 + 1)
        for bin in 0...count / 2 {
            let referencePower = referenceReal[bin] * referenceReal[bin]
                + referenceImaginary[bin] * referenceImaginary[bin]
            guard referencePower >= usableReferencePower else { continue }
            let crossReal = measurementReal[bin] * referenceReal[bin]
                + measurementImaginary[bin] * referenceImaginary[bin]
            let crossImaginary = measurementImaginary[bin] * referenceReal[bin]
                - measurementReal[bin] * referenceImaginary[bin]
            let transferBinReal = crossReal / (referencePower + regularization)
            let transferBinImaginary = crossImaginary / (referencePower + regularization)
            transferReal[bin] = transferBinReal
            transferImaginary[bin] = transferBinImaginary
            validBins[bin] = true
            if bin > 0, bin < count / 2 {
                transferReal[count - bin] = transferBinReal
                transferImaginary[count - bin] = -transferBinImaginary
            }
        }
        fft(real: &transferReal, imaginary: &transferImaginary, inverse: true)

        let frequencies = SpectrogramAnalyzer.bandCenterFrequencies(for: scale)
        let binWidth = frame.sampleRate / Double(count)
        var points: [TransferFunctionPoint] = []
        points.reserveCapacity(frequencies.count)
        for frequency in frequencies {
            let nearestBin = min(count / 2, max(1, Int((frequency / binWidth).rounded())))
            guard validBins[nearestBin] else { continue }
            let magnitude = gatedMagnitude(
                impulseResponse: transferReal,
                frequency: frequency,
                sampleRate: frame.sampleRate
            )
            guard magnitude.isFinite, magnitude > 1e-12 else { continue }
            points.append(TransferFunctionPoint(
                frequency: frequency,
                magnitudeDB: 20 * log10(magnitude)
            ))
        }
        guard points.count >= max(6, frequencies.count / 3) else {
            return TransferFunctionAnalysis(validity: .invalidReference, curve: nil)
        }

        let displayRange = automaticDisplayRange(points)
        return TransferFunctionAnalysis(
            validity: .valid,
            curve: TransferFunctionCurve(
                points: points,
                frequencyScale: scale,
                delaySeconds: delaySamples / frame.sampleRate,
                displayLowerDB: displayRange.lower,
                displayUpperDB: displayRange.upper,
                capturedAtUptime: frame.capturedAtUptime
            )
        )
    }

    static func automaticDisplayRange(
        _ points: [TransferFunctionPoint]
    ) -> (lower: Double, upper: Double) {
        let automaticGainLevels = points.compactMap { point in
            automaticGainFrequencyRange.contains(point.frequency)
                && point.magnitudeDB.isFinite
                ? point.magnitudeDB
                : nil
        }
        guard let minimum = automaticGainLevels.min(),
              let maximum = automaticGainLevels.max() else {
            return (-12, 12)
        }
        let contentSpan = maximum - minimum
        let span = max(12, contentSpan + 6)
        let center = (minimum + maximum) / 2
        return (center - span / 2, center + span / 2)
    }

    static func smoothedAutomaticDisplayRange(
        current: (lower: Double, upper: Double),
        previous: (lower: Double, upper: Double)?,
        elapsedTime: TimeInterval?
    ) -> (lower: Double, upper: Double) {
        guard current.lower.isFinite,
              current.upper.isFinite,
              current.lower <= current.upper else { return (-12, 12) }
        guard let previous,
              previous.lower.isFinite,
              previous.upper.isFinite,
              previous.lower <= previous.upper,
              let elapsedTime,
              elapsedTime.isFinite,
              elapsedTime > 0 else { return current }

        let currentCenter = current.lower / 2 + current.upper / 2
        let previousCenter = previous.lower / 2 + previous.upper / 2
        let alpha = -expm1(-elapsedTime / automaticGainSmoothingTimeConstant)
        let center = previousCenter + alpha * (currentCenter - previousCenter)
        let halfSpan = (current.upper - current.lower) / 2
        return (center - halfSpan, center + halfSpan)
    }

    private static func normalizedCorrelation(
        measurement: [Float],
        reference: [Float],
        delay: Int
    ) -> Double {
        let measurementStart = max(0, delay)
        let referenceStart = max(0, -delay)
        let pairCount = min(
            measurement.count - measurementStart,
            reference.count - referenceStart
        )
        guard pairCount > 0 else { return 0 }
        var cross = 0.0
        var measurementEnergy = 0.0
        var referenceEnergy = 0.0
        for offset in 0..<pairCount {
            let measured = Double(measurement[measurementStart + offset])
            let reference = Double(reference[referenceStart + offset])
            cross += measured * reference
            measurementEnergy += measured * measured
            referenceEnergy += reference * reference
        }
        let denominator = sqrt(measurementEnergy * referenceEnergy)
        guard denominator > 1e-20 else { return 0 }
        return abs(cross) / denominator
    }

    static func gatedMagnitude(
        impulseResponse: [Double],
        frequency: Double,
        sampleRate: Double
    ) -> Double {
        let count = impulseResponse.count
        let effectiveWindowDuration = windowDuration(
            for: frequency,
            sampleRate: sampleRate,
            frameCount: count
        )
        let postSamples = min(
            count / 2 - 1,
            max(1, Int((effectiveWindowDuration * sampleRate).rounded()))
        )
        let preSamples = min(
            count / 2 - 1,
            max(1, Int((min(preWindowDuration, effectiveWindowDuration / 4) * sampleRate).rounded()))
        )
        var real = 0.0
        var imaginary = 0.0
        let signalStep = -2 * Double.pi * frequency / sampleRate
        let signalStepReal = cos(signalStep)
        let signalStepImaginary = sin(signalStep)

        var signalReal = cos(signalStep * Double(-preSamples))
        var signalImaginary = sin(signalStep * Double(-preSamples))
        let preWindowStep = Double.pi / Double(preSamples)
        let preWindowStepReal = cos(preWindowStep)
        let preWindowStepImaginary = sin(preWindowStep)
        var windowReal = 1.0
        var windowImaginary = 0.0
        for offset in -preSamples..<0 {
            let weight = 0.5 - 0.5 * windowReal
            let value = impulseResponse[count + offset] * weight
            real += value * signalReal
            imaginary += value * signalImaginary
            advance(
                real: &signalReal,
                imaginary: &signalImaginary,
                stepReal: signalStepReal,
                stepImaginary: signalStepImaginary
            )
            advance(
                real: &windowReal,
                imaginary: &windowImaginary,
                stepReal: preWindowStepReal,
                stepImaginary: preWindowStepImaginary
            )
        }

        let postWindowStep = Double.pi / Double(postSamples)
        let postWindowStepReal = cos(postWindowStep)
        let postWindowStepImaginary = sin(postWindowStep)
        windowReal = 1
        windowImaginary = 0
        for offset in 0...postSamples {
            let weight = 0.5 + 0.5 * windowReal
            let value = impulseResponse[offset] * weight
            real += value * signalReal
            imaginary += value * signalImaginary
            advance(
                real: &signalReal,
                imaginary: &signalImaginary,
                stepReal: signalStepReal,
                stepImaginary: signalStepImaginary
            )
            advance(
                real: &windowReal,
                imaginary: &windowImaginary,
                stepReal: postWindowStepReal,
                stepImaginary: postWindowStepImaginary
            )
        }
        return hypot(real, imaginary)
    }

    private static func advance(
        real: inout Double,
        imaginary: inout Double,
        stepReal: Double,
        stepImaginary: Double
    ) {
        let nextReal = real * stepReal - imaginary * stepImaginary
        imaginary = real * stepImaginary + imaginary * stepReal
        real = nextReal
    }

    private static func fft(
        real: inout [Double],
        imaginary: inout [Double],
        inverse: Bool
    ) {
        let count = real.count
        guard count > 1, count.nonzeroBitCount == 1, imaginary.count == count else { return }
        var target = 0
        for index in 0..<count {
            if index < target {
                real.swapAt(index, target)
                imaginary.swapAt(index, target)
            }
            var bit = count >> 1
            while target & bit != 0 {
                target ^= bit
                bit >>= 1
            }
            target ^= bit
        }
        var length = 2
        while length <= count {
            let angle = (inverse ? 2 : -2) * Double.pi / Double(length)
            let stepReal = cos(angle)
            let stepImaginary = sin(angle)
            let halfLength = length >> 1
            var start = 0
            while start < count {
                var phaseReal = 1.0
                var phaseImaginary = 0.0
                for offset in 0..<halfLength {
                    let even = start + offset
                    let odd = even + halfLength
                    let oddReal = real[odd] * phaseReal - imaginary[odd] * phaseImaginary
                    let oddImaginary = real[odd] * phaseImaginary + imaginary[odd] * phaseReal
                    let evenReal = real[even]
                    let evenImaginary = imaginary[even]
                    real[even] = evenReal + oddReal
                    imaginary[even] = evenImaginary + oddImaginary
                    real[odd] = evenReal - oddReal
                    imaginary[odd] = evenImaginary - oddImaginary
                    let nextPhaseReal = phaseReal * stepReal - phaseImaginary * stepImaginary
                    phaseImaginary = phaseReal * stepImaginary + phaseImaginary * stepReal
                    phaseReal = nextPhaseReal
                }
                start += length
            }
            length <<= 1
        }
        if inverse {
            let scale = 1 / Double(count)
            for index in 0..<count {
                real[index] *= scale
                imaginary[index] *= scale
            }
        }
    }
}

final class TransferFunctionAnalyzer: @unchecked Sendable {
    private static let maximumPendingFrameCount = 16
    private let queue = DispatchQueue(label: "SPLMan.transfer-function", qos: .utility)
    private let stateLock = NSLock()
    private var generation: UInt64 = 0
    private var isWorkerRunning = false
    private var pendingFrames: [TransferSignalFrame] = []
    private var pendingRange: SpectrogramFrequencyRange = .full
    private var pendingCompletion: (@MainActor (TransferFunctionAnalysis) -> Void)?
    private var pendingReset = false

    // Accessed only by `queue`.
    private var processedGeneration: UInt64?
    private var assembledMeasurement: [Float] = []
    private var assembledReference: [Float] = []
    private var assemblySampleRate: Double?
    private var assemblyStartUptime: TimeInterval?
    private var expectedNextFrameUptime: TimeInterval?
    private var previousDelaySamples: Double?
    private var previousCurve: TransferFunctionCurve?
    private var curveAverager = TransferFunctionAverager()

    func invalidate() {
        stateLock.lock()
        generation &+= 1
        pendingFrames.removeAll(keepingCapacity: true)
        pendingReset = true
        stateLock.unlock()
    }

    func analyze(
        _ frames: [TransferSignalFrame],
        range: SpectrogramFrequencyRange,
        completion: @escaping @MainActor (TransferFunctionAnalysis) -> Void
    ) {
        guard !frames.isEmpty else { return }
        stateLock.lock()
        pendingFrames.append(contentsOf: frames)
        let latestFrame = frames[frames.count - 1]
        let framesPerBlock = max(
            1,
            Int(ceil(
                Double(TransferFunctionDSP.analysisFrameCount(
                    sampleRate: latestFrame.sampleRate
                )) / Double(max(1, latestFrame.measurement.count))
            ))
        )
        // Two blocks of backlog: a single main-thread hiccup that delivers a
        // few frames at once must not discard the partially assembled block.
        let pendingLimit = min(Self.maximumPendingFrameCount, max(4, 2 * framesPerBlock))
        if pendingFrames.count > pendingLimit {
            pendingFrames.removeFirst(
                pendingFrames.count - pendingLimit
            )
            pendingReset = true
        }
        pendingRange = range
        pendingCompletion = completion
        let shouldStartWorker = !isWorkerRunning
        if shouldStartWorker { isWorkerRunning = true }
        stateLock.unlock()
        if shouldStartWorker { queue.async { [weak self] in self?.processPendingFrames() } }
    }

    private func processPendingFrames() {
        while true {
            stateLock.lock()
            guard !pendingFrames.isEmpty else {
                isWorkerRunning = false
                stateLock.unlock()
                return
            }
            let frames = pendingFrames
            pendingFrames.removeAll(keepingCapacity: true)
            let range = pendingRange
            let completion = pendingCompletion
            let requestedGeneration = generation
            let shouldReset = pendingReset
            pendingReset = false
            stateLock.unlock()

            if processedGeneration != requestedGeneration {
                resetAssembly(generation: requestedGeneration)
            } else if shouldReset {
                resetAssembly(
                    generation: requestedGeneration,
                    preservingCurveHistory: true
                )
            }
            for frame in frames {
                append(
                    frame,
                    range: range,
                    generation: requestedGeneration,
                    completion: completion
                )
            }
        }
    }

    private func append(
        _ frame: TransferSignalFrame,
        range: SpectrogramFrequencyRange,
        generation: UInt64,
        completion: (@MainActor (TransferFunctionAnalysis) -> Void)?
    ) {
        guard frame.measurement.count == frame.reference.count,
              !frame.measurement.isEmpty,
              frame.sampleRate > 0 else {
            resetAssembly(generation: generation)
            return
        }
        if assemblySampleRate != frame.sampleRate {
            resetAssembly(generation: generation)
        } else if expectedNextFrameUptime.map({
                !TransferFunctionDSP.framesAreContinuous(
                    expectedNextUptime: $0,
                    nextUptime: frame.capturedAtUptime,
                    sampleRate: frame.sampleRate
                )
            }) == true {
            resetAssembly(generation: generation, preservingCurveHistory: true)
        }
        if assembledMeasurement.isEmpty {
            assemblySampleRate = frame.sampleRate
            assemblyStartUptime = frame.capturedAtUptime
        }
        assembledMeasurement.append(contentsOf: frame.measurement)
        assembledReference.append(contentsOf: frame.reference)
        expectedNextFrameUptime = frame.capturedAtUptime
            + Double(frame.measurement.count) / frame.sampleRate

        let blockSize = TransferFunctionDSP.analysisFrameCount(sampleRate: frame.sampleRate)
        while assembledMeasurement.count >= blockSize {
            let blockStart = assemblyStartUptime ?? frame.capturedAtUptime
            let measurement = Array(assembledMeasurement.prefix(blockSize))
            let reference = Array(assembledReference.prefix(blockSize))
            assembledMeasurement.removeFirst(blockSize)
            assembledReference.removeFirst(blockSize)
            assemblyStartUptime = blockStart + Double(blockSize) / frame.sampleRate

            var analysis = TransferFunctionDSP.analyze(
                frame: TransferSignalFrame(
                    measurement: measurement,
                    reference: reference,
                    sampleRate: frame.sampleRate,
                    capturedAtUptime: blockStart
                ),
                range: range,
                preferredDelaySamples: previousDelaySamples
            )
            analysis = averaged(
                analysis,
                blockDuration: Double(blockSize) / frame.sampleRate
            )
            if let curve = analysis.curve {
                previousDelaySamples = curve.delaySeconds * frame.sampleRate
                previousCurve = curve
            }
            publish(analysis, generation: generation, completion: completion)
        }
    }

    private func averaged(
        _ analysis: TransferFunctionAnalysis,
        blockDuration: TimeInterval
    ) -> TransferFunctionAnalysis {
        guard let curve = analysis.curve else { return analysis }
        let averagedPoints = curveAverager.average(
            points: curve.points,
            frequencyScale: curve.frequencyScale,
            capturedAtUptime: curve.capturedAtUptime,
            blockDuration: blockDuration
        )
        let automaticDisplayRange = TransferFunctionDSP.automaticDisplayRange(
            averagedPoints
        )
        let previousDisplayRange = previousCurve.flatMap { previous -> (
            lower: Double,
            upper: Double,
            elapsedTime: TimeInterval
        )? in
            guard previous.frequencyScale == curve.frequencyScale else { return nil }
            return (
                previous.displayLowerDB,
                previous.displayUpperDB,
                curve.capturedAtUptime - previous.capturedAtUptime
            )
        }
        let displayRange = TransferFunctionDSP.smoothedAutomaticDisplayRange(
            current: automaticDisplayRange,
            previous: previousDisplayRange.map { ($0.lower, $0.upper) },
            elapsedTime: previousDisplayRange?.elapsedTime
        )
        return TransferFunctionAnalysis(
            validity: .valid,
            curve: TransferFunctionCurve(
                points: averagedPoints,
                frequencyScale: curve.frequencyScale,
                delaySeconds: curve.delaySeconds,
                displayLowerDB: displayRange.lower,
                displayUpperDB: displayRange.upper,
                capturedAtUptime: curve.capturedAtUptime
            )
        )
    }

    private func publish(
        _ analysis: TransferFunctionAnalysis,
        generation: UInt64,
        completion: (@MainActor (TransferFunctionAnalysis) -> Void)?
    ) {
        guard let completion else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let isCurrent = generation == self.generation
            self.stateLock.unlock()
            guard isCurrent else { return }
            completion(analysis)
        }
    }

    private func resetAssembly(
        generation: UInt64,
        preservingCurveHistory: Bool = false
    ) {
        processedGeneration = generation
        assembledMeasurement.removeAll(keepingCapacity: true)
        assembledReference.removeAll(keepingCapacity: true)
        assemblyStartUptime = nil
        expectedNextFrameUptime = nil
        if !preservingCurveHistory {
            assemblySampleRate = nil
            previousDelaySamples = nil
            previousCurve = nil
            curveAverager.reset()
        }
    }
}
