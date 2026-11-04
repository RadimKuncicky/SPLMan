import Foundation

struct SpectrogramSignalFrame {
    let samples: [Float]
    let sampleRate: Double
    let capturedAtUptime: TimeInterval

    var coveredDuration: TimeInterval {
        Double(samples.count) / sampleRate
    }
}

struct SpectrogramColumn: Equatable {
    let capturedAtUptime: TimeInterval
    let coveredDuration: TimeInterval
    let levelsDBFS: [Float]
    let frequencies: [Double]
    let frequencyScale: SpectrogramFrequencyScale?

    init(
        capturedAtUptime: TimeInterval,
        coveredDuration: TimeInterval,
        levelsDBFS: [Float],
        frequencies: [Double] = [],
        frequencyScale: SpectrogramFrequencyScale? = nil
    ) {
        self.capturedAtUptime = capturedAtUptime
        self.coveredDuration = coveredDuration
        self.levelsDBFS = levelsDBFS
        self.frequencies = frequencies
        self.frequencyScale = frequencyScale
    }
}

struct SpectrogramLevelScale {
    // Calibration uses RMS levels, while the FFT is normalized so a
    // full-scale sine has 0 dBFS peak power.
    static let fullScaleSinePeakToRMSDB = -10 * log10(2.0)

    let upperLevelDB: Double
    let dynamicRangeDB: Double
    let calibrationOffsetDB: Double?

    var displayedUpperLevelDB: Double {
        calibrationOffsetDB == nil ? 0 : upperLevelDB
    }

    var lowerLevelDB: Double { displayedUpperLevelDB - dynamicRangeDB }

    func displayedLevelDB(for levelDBFS: Double) -> Double {
        guard let calibrationOffsetDB else { return levelDBFS }
        return levelDBFS + calibrationOffsetDB + Self.fullScaleSinePeakToRMSDB
    }

    func normalizedValue(for levelDBFS: Double) -> Double {
        guard dynamicRangeDB > 0 else { return 0 }
        return min(
            1,
            max(0, (displayedLevelDB(for: levelDBFS) - lowerLevelDB) / dynamicRangeDB)
        )
    }
}

struct SpectrogramFrequencyScale: Equatable, Sendable {
    let lowerFrequency: Double
    let upperFrequency: Double

    init(range: SpectrogramFrequencyRange) {
        lowerFrequency = range.lowerFrequency
        upperFrequency = range.upperFrequency
    }

    init?(
        sampleRate: Double,
        frameCount: Int,
        range: SpectrogramFrequencyRange
    ) {
        guard sampleRate > 0, frameCount > 1 else { return nil }
        let lower = max(range.lowerFrequency, sampleRate / Double(frameCount))
        let upper = min(range.upperFrequency, sampleRate / 2)
        guard lower < upper else { return nil }
        lowerFrequency = lower
        upperFrequency = upper
    }

    func position(for frequency: Double) -> Double? {
        guard frequency >= lowerFrequency, frequency <= upperFrequency else { return nil }
        return log(frequency / lowerFrequency) / log(upperFrequency / lowerFrequency)
    }
}

enum SpectrogramTimeline {
    static func expiredPrefixCount(
        in columns: [SpectrogramColumn],
        referenceUptime: TimeInterval,
        historyDuration: TimeInterval
    ) -> Int {
        let cutoff = referenceUptime - historyDuration
        return columns.firstIndex {
            $0.capturedAtUptime + max(0, $0.coveredDuration) >= cutoff
        } ?? columns.count
    }

    static func timeFraction(
        for timestamp: TimeInterval,
        referenceUptime: TimeInterval,
        historyDuration: TimeInterval
    ) -> Double {
        guard historyDuration > 0 else { return 1 }
        return min(1, max(0, (timestamp - referenceUptime + historyDuration) / historyDuration))
    }

    static func visibleEndUptime(
        for column: SpectrogramColumn,
        nextColumnUptime: TimeInterval?,
        referenceUptime: TimeInterval
    ) -> TimeInterval {
        min(
            referenceUptime,
            min(
                nextColumnUptime ?? referenceUptime,
                column.capturedAtUptime + max(0, column.coveredDuration)
            )
        )
    }
}

struct SpectrogramRasterRow: Equatable {
    let pixelIndex: Int
    let levelsDBFS: [Float]
    let frequencies: [Double]
}

struct SpectrogramRasterRun: Equatable {
    let firstPixelIndex: Int
    let pixelCount: Int
    let levelsDBFS: [Float]
    let frequencies: [Double]
}

enum SpectrogramRasterizer {
    static func rows(
        for columns: [SpectrogramColumn],
        referenceUptime: TimeInterval,
        historyDuration: TimeInterval,
        pixelHeight: Int
    ) -> [SpectrogramRasterRow] {
        guard historyDuration > 0,
              pixelHeight > 0,
              let bandCount = columns.first?.levelsDBFS.count,
              bandCount > 0 else { return [] }
        let frequencies = columns.first?.frequencies ?? []

        var levelsByPixel = Array<[Float]?>(repeating: nil, count: pixelHeight)

        for (columnIndex, column) in columns.enumerated() {
            guard column.levelsDBFS.count == bandCount,
                  column.frequencies == frequencies else { continue }
            let nextTimestamp = columnIndex + 1 < columns.count
                ? columns[columnIndex + 1].capturedAtUptime
                : nil
            let visibleEnd = SpectrogramTimeline.visibleEndUptime(
                for: column,
                nextColumnUptime: nextTimestamp,
                referenceUptime: referenceUptime
            )
            let startFraction = SpectrogramTimeline.timeFraction(
                for: column.capturedAtUptime,
                referenceUptime: referenceUptime,
                historyDuration: historyDuration
            )
            let endFraction = SpectrogramTimeline.timeFraction(
                for: visibleEnd,
                referenceUptime: referenceUptime,
                historyDuration: historyDuration
            )
            guard endFraction > startFraction else { continue }

            let firstPixel = max(0, Int(floor(startFraction * Double(pixelHeight))))
            let pixelAfterLast = min(
                pixelHeight,
                Int(ceil(endFraction * Double(pixelHeight)))
            )
            guard firstPixel < pixelAfterLast else { continue }

            for pixelIndex in firstPixel..<pixelAfterLast {
                if levelsByPixel[pixelIndex] == nil {
                    levelsByPixel[pixelIndex] = column.levelsDBFS
                    continue
                }
                for bandIndex in 0..<bandCount {
                    levelsByPixel[pixelIndex]![bandIndex] = max(
                        levelsByPixel[pixelIndex]![bandIndex],
                        column.levelsDBFS[bandIndex]
                    )
                }
            }
        }

        return levelsByPixel.enumerated().compactMap { pixelIndex, levels in
            levels.map {
                SpectrogramRasterRow(
                    pixelIndex: pixelIndex,
                    levelsDBFS: $0,
                    frequencies: frequencies
                )
            }
        }
    }

    static func runs(
        for columns: [SpectrogramColumn],
        referenceUptime: TimeInterval,
        historyDuration: TimeInterval,
        pixelHeight: Int
    ) -> [SpectrogramRasterRun] {
        let rows = rows(
            for: columns,
            referenceUptime: referenceUptime,
            historyDuration: historyDuration,
            pixelHeight: pixelHeight
        )
        guard let firstRow = rows.first else { return [] }

        var runs: [SpectrogramRasterRun] = []
        var firstPixelIndex = firstRow.pixelIndex
        var pixelCount = 1
        var levelsDBFS = firstRow.levelsDBFS
        let frequencies = firstRow.frequencies

        for row in rows.dropFirst() {
            if row.pixelIndex == firstPixelIndex + pixelCount,
               row.levelsDBFS == levelsDBFS {
                pixelCount += 1
                continue
            }
            runs.append(SpectrogramRasterRun(
                firstPixelIndex: firstPixelIndex,
                pixelCount: pixelCount,
                levelsDBFS: levelsDBFS,
                frequencies: frequencies
            ))
            firstPixelIndex = row.pixelIndex
            pixelCount = 1
            levelsDBFS = row.levelsDBFS
        }
        runs.append(SpectrogramRasterRun(
            firstPixelIndex: firstPixelIndex,
            pixelCount: pixelCount,
            levelsDBFS: levelsDBFS,
            frequencies: frequencies
        ))
        return runs
    }
}

/// Performs the FFT away from the real-time audio callback and drops work
/// instead of building a backlog if the previous transform is still running.
final class SpectrogramAnalyzer: @unchecked Sendable {
    static let fftSize = 8_192
    static let maximumFrameCount = fftSize
    static let bandsPerOctave = 24

    private let queue = DispatchQueue(label: "SPLMan.spectrogram", qos: .utility)
    private let stateLock = NSLock()
    private var generation: UInt64 = 0
    private var isBusy = false

    var canAcceptAnalysis: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !isBusy
    }

    func invalidate() {
        stateLock.lock()
        generation &+= 1
        stateLock.unlock()
    }

    static func frameCount(forSampleRate sampleRate: Double) -> Int {
        fftSize
    }

    func analyze(
        _ frames: [SpectrogramSignalFrame],
        range: SpectrogramFrequencyRange,
        completion: @escaping @MainActor ([SpectrogramColumn]) -> Void
    ) {
        guard !frames.isEmpty else { return }
        stateLock.lock()
        guard !isBusy else {
            stateLock.unlock()
            return
        }
        isBusy = true
        let requestedGeneration = generation
        stateLock.unlock()

        queue.async { [self] in
            var columns: [SpectrogramColumn] = []
            columns.reserveCapacity(frames.count)
            for frame in frames {
                guard let frequencyScale = SpectrogramFrequencyScale(
                    sampleRate: frame.sampleRate,
                    frameCount: frame.samples.count,
                    range: range
                ) else { continue }
                let levelsDBFS = Self.spectrum(
                    samples: frame.samples,
                    sampleRate: frame.sampleRate,
                    range: range
                )
                guard !levelsDBFS.isEmpty else { continue }
                let frequencies = Self.spectrogramCenterFrequencies(
                    for: frequencyScale,
                    binWidth: frame.sampleRate / Double(frame.samples.count)
                )
                guard frequencies.count == levelsDBFS.count else { continue }
                let column = SpectrogramColumn(
                    capturedAtUptime: frame.capturedAtUptime,
                    coveredDuration: frame.coveredDuration,
                    levelsDBFS: levelsDBFS,
                    frequencies: frequencies,
                    frequencyScale: frequencyScale
                )
                if let previous = columns.last,
                   previous.frequencyScale == column.frequencyScale,
                   previous.frequencies == column.frequencies,
                   previous.levelsDBFS.count == column.levelsDBFS.count,
                   abs(
                       previous.capturedAtUptime + previous.coveredDuration
                           - column.capturedAtUptime
                   ) <= max(2 / frame.sampleRate, 0.000_001) {
                    var mergedLevels = previous.levelsDBFS
                    for band in mergedLevels.indices {
                        mergedLevels[band] = max(mergedLevels[band], column.levelsDBFS[band])
                    }
                    columns[columns.count - 1] = SpectrogramColumn(
                        capturedAtUptime: previous.capturedAtUptime,
                        coveredDuration: column.capturedAtUptime
                            + column.coveredDuration
                            - previous.capturedAtUptime,
                        levelsDBFS: mergedLevels,
                        frequencies: frequencies,
                        frequencyScale: frequencyScale
                    )
                } else {
                    columns.append(column)
                }
            }
            stateLock.lock()
            isBusy = false
            stateLock.unlock()
            DispatchQueue.main.async {
                self.stateLock.lock()
                let isCurrent = requestedGeneration == self.generation
                self.stateLock.unlock()
                guard isCurrent else { return }
                completion(columns)
            }
        }
    }

    static func spectrum(
        samples: [Float],
        sampleRate: Double,
        range: SpectrogramFrequencyRange
    ) -> [Float] {
        let count = samples.count
        guard count == fftSize, sampleRate > 0 else { return [] }

        var real = [Double](repeating: 0, count: count)
        var imaginary = [Double](repeating: 0, count: count)
        let denominator = Double(count - 1)
        var windowEnergy = 0.0
        for index in samples.indices {
            let window = 0.5 - 0.5 * cos(2 * .pi * Double(index) / denominator)
            real[index] = Double(samples[index]) * window
            windowEnergy += window * window
        }

        var target = 0
        for index in 0..<count {
            if index < target {
                real.swapAt(index, target)
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
            let angle = -2 * Double.pi / Double(length)
            let phaseStepReal = cos(angle)
            let phaseStepImaginary = sin(angle)
            let halfLength = length >> 1
            var start = 0
            while start < count {
                var phaseReal = 1.0
                var phaseImaginary = 0.0
                for offset in 0..<halfLength {
                    let evenIndex = start + offset
                    let oddIndex = evenIndex + halfLength
                    let oddReal = real[oddIndex] * phaseReal
                        - imaginary[oddIndex] * phaseImaginary
                    let oddImaginary = real[oddIndex] * phaseImaginary
                        + imaginary[oddIndex] * phaseReal
                    let evenReal = real[evenIndex]
                    let evenImaginary = imaginary[evenIndex]
                    real[evenIndex] = evenReal + oddReal
                    imaginary[evenIndex] = evenImaginary + oddImaginary
                    real[oddIndex] = evenReal - oddReal
                    imaginary[oddIndex] = evenImaginary - oddImaginary
                    let nextPhaseReal = phaseReal * phaseStepReal
                        - phaseImaginary * phaseStepImaginary
                    phaseImaginary = phaseReal * phaseStepImaginary
                        + phaseImaginary * phaseStepReal
                    phaseReal = nextPhaseReal
                }
                start += length
            }
            length <<= 1
        }

        guard let frequencyScale = SpectrogramFrequencyScale(
            sampleRate: sampleRate,
            frameCount: count,
            range: range
        ) else { return [] }

        // One-sided power normalization. Integrating the Hann main lobe of a
        // full-scale, bin-centred sine yields approximately 1 (0 dBFS).
        let powerScale = 4 / (Double(count) * windowEnergy)
        let binWidth = sampleRate / Double(count)
        let lastBin = min(count / 2, Int(ceil(frequencyScale.upperFrequency / binWidth)))
        var binPower = [Double](repeating: 0, count: lastBin + 1)
        if lastBin >= 1 {
            for bin in 1...lastBin {
                binPower[bin] = (
                    real[bin] * real[bin] + imaginary[bin] * imaginary[bin]
                ) * powerScale
            }
        }

        return spectrogramLevels(
            binPower: binPower,
            binWidth: binWidth,
            frequencyScale: frequencyScale
        )
    }

    static func spectrogramLevels(
        binPower: [Double],
        binWidth: Double,
        frequencyScale: SpectrogramFrequencyScale
    ) -> [Float] {
        guard binPower.count > 1, binWidth > 0 else { return [] }
        let lastBin = binPower.count - 1
        let transitionFrequency = resolvedBandTransitionFrequency(binWidth: binWidth)
        return spectrogramCenterFrequencies(
            for: frequencyScale,
            binWidth: binWidth
        ).map { centerFrequency in
            if centerFrequency < transitionFrequency {
                let bin = Int((centerFrequency / binWidth).rounded())
                guard bin >= 1, bin <= lastBin else { return -200 }
                let nominalBounds = nominalSmoothingFrequencyBounds(
                    centerFrequency: centerFrequency
                )
                let nominalBandwidth = nominalBounds.upper - nominalBounds.lower
                let normalizedPower = binPower[bin] * nominalBandwidth / binWidth
                return Float(10 * log10(max(normalizedPower, 1e-20)))
            }

            let bounds = nominalSmoothingFrequencyBounds(centerFrequency: centerFrequency)
            let lowBin = max(1, Int(floor(bounds.lower / binWidth - 0.5)))
            let highBin = min(lastBin, Int(ceil(bounds.upper / binWidth + 0.5)))
            guard lowBin <= highBin else { return 0 }

            var bandPower = 0.0
            for bin in lowBin...highBin {
                let binLower = (Double(bin) - 0.5) * binWidth
                let binUpper = (Double(bin) + 0.5) * binWidth
                let overlap = max(
                    0,
                    min(bounds.upper, binUpper) - max(bounds.lower, binLower)
                )
                bandPower += binPower[bin] * overlap / binWidth
            }
            return Float(10 * log10(max(bandPower, 1e-20)))
        }
    }

    /// Frequencies used only by the spectrogram. Native FFT bins are shown
    /// until a 1/24-octave band is wide enough to resolve a Hann main lobe.
    /// Each native bin is normalized to the nominal 1/24-octave bandwidth so
    /// the fixed crossover does not introduce a level step, but bins are never
    /// merged below the crossover. Transfer-function analysis keeps its
    /// independent 1/24-octave grid.
    static func spectrogramCenterFrequencies(
        for scale: SpectrogramFrequencyScale,
        binWidth: Double
    ) -> [Double] {
        guard binWidth > 0 else { return [] }
        let transitionFrequency = resolvedBandTransitionFrequency(binWidth: binWidth)
        let firstBin = max(1, Int(ceil(scale.lowerFrequency / binWidth)))
        let lastNativeBin = min(
            Int(floor(scale.upperFrequency / binWidth)),
            Int(ceil(transitionFrequency / binWidth)) - 1
        )
        var frequencies: [Double] = []
        if firstBin <= lastNativeBin {
            frequencies.reserveCapacity(lastNativeBin - firstBin + 1)
            for bin in firstBin...lastNativeBin {
                frequencies.append(Double(bin) * binWidth)
            }
        }
        frequencies.append(contentsOf: bandCenterFrequencies(for: scale).filter { frequency in
            frequency >= transitionFrequency
                && frequency <= scale.upperFrequency
                && (frequencies.last.map { $0 < frequency } ?? true)
        })
        return frequencies
    }

    static func resolvedBandTransitionFrequency(binWidth: Double) -> Double {
        guard binWidth > 0 else { return .infinity }
        let unitBounds = nominalSmoothingFrequencyBounds(centerFrequency: 1)
        return 3 * binWidth / (unitBounds.upper - unitBounds.lower)
    }

    static func bandCenterFrequencies(for scale: SpectrogramFrequencyScale) -> [Double] {
        let octaveSpan = log2(scale.upperFrequency / scale.lowerFrequency)
        let intervalCount = max(1, Int(floor(octaveSpan * Double(bandsPerOctave))))
        return (0...intervalCount).map { index in
            scale.lowerFrequency * pow(2, Double(index) / Double(bandsPerOctave))
        }
    }

    static func nominalSmoothingFrequencyBounds(
        centerFrequency: Double
    ) -> (lower: Double, upper: Double) {
        let octaveHalfStep = 1 / (2 * Double(bandsPerOctave))
        return (
            centerFrequency * pow(2, -octaveHalfStep),
            centerFrequency * pow(2, octaveHalfStep)
        )
    }
}
