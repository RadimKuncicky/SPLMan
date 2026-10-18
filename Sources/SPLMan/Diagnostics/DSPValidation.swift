import Foundation

/// Independent numerical checks for the streaming DSP. This suite is kept
/// separate from the UI/logger self-test so it can also be compiled as a
/// small command-line validation target.
enum DSPValidation {
    static func run() -> Bool {
        var failures: [String] = []
        testSampleRateValidation(&failures)
        testTimeWeighting(&failures)
        testASlowFallingStep(&failures)
        testFrequencyWeighting(&failures)
        testOneSecondLeqAndSignals(&failures)
        testBufferIndependence(&failures)
        testPerSecondMaximaAndReset(&failures)
        testDiscontinuityInvalidation(&failures)
        testBoundedSecondQueue(&failures)
        testAcceleratedTwentyFourHours(&failures)

        if failures.isEmpty {
            print("SPLMan DSP validation: PASS")
            return true
        }
        print("SPLMan DSP validation: FAIL")
        failures.forEach { print("- \($0)") }
        return false
    }

    private static func testSampleRateValidation(_ failures: inout [String]) {
        for valid in [32_000.0, 44_100.0, 48_000.0, 96_000.0, 192_000.0] {
            if !SPLProcessor.isValidSampleRate(valid) {
                failures.append("Valid sample rate \(valid) Hz was rejected")
            }
        }
        for invalid in [0, 22_050, 48_000.5, .infinity, .nan] {
            if SPLProcessor.isValidSampleRate(invalid) {
                failures.append("Invalid sample rate \(invalid) Hz was accepted")
            }
        }
    }

    private static func testTimeWeighting(_ failures: inout [String]) {
        let sampleRate = 48_000.0
        for timeConstant in [0.125, 1.0] {
            var weighting = ExponentialTimeWeighting(
                timeConstant: timeConstant,
                sampleRate: sampleRate
            )
            let frameCount = Int(sampleRate * timeConstant)
            for _ in 0..<frameCount { _ = weighting.process(1) }
            let analytic = 1 - exp(-Double(frameCount) / (sampleRate * timeConstant))
            if abs(weighting.energy - analytic) > 1e-11 {
                failures.append("\(timeConstant) s time weighting differs from analytic step response")
            }
        }
    }

    private static func testASlowFallingStep(_ failures: inout [String]) {
        let sampleRate = 32_000
        let tone = (0..<(sampleRate * 8)).map { index in
            Float(0.25 * sin(2 * Double.pi * 1_000 * Double(index) / Double(sampleRate)))
        }
        let silenceTenth = Array(repeating: Float.zero, count: sampleRate / 10)
        let chunkPatterns = [[64], [257, 2_048], [tone.count]]
        var referenceLevels: [Double]?

        for chunks in chunkPatterns {
            let processor = SPLProcessor(sampleRate: Double(sampleRate))
            guard let initial = latestSnapshot(
                afterProcessing: tone,
                processor: processor,
                chunks: chunks
            )?.aSlow else {
                failures.append("A Slow falling-step test did not produce an initial level")
                return
            }

            var levels = [initial]
            for step in 1...10 {
                guard let level = latestSnapshot(
                    afterProcessing: silenceTenth,
                    processor: processor,
                    chunks: chunks
                )?.aSlow else {
                    failures.append("A Slow falling-step test lost its value at step \(step)")
                    return
                }
                levels.append(level)

                // With a one-second exponential time constant, silence makes
                // energy fall as exp(-t), or 10/log(10) dB per second.
                let elapsed = Double(step) / 10
                let expected = initial - 10 / log(10) * elapsed
                if abs(level - expected) > 0.02 {
                    failures.append(String(
                        format: "A Slow falling step at %.1f s was %.3f dB; expected %.3f dB",
                        elapsed, level, expected
                    ))
                }
            }

            if let referenceLevels {
                for index in levels.indices where abs(levels[index] - referenceLevels[index]) > 1e-10 {
                    failures.append("A Slow falling step depends on audio buffer boundaries")
                    break
                }
            } else {
                referenceLevels = levels
            }
        }
    }

    private static func testFrequencyWeighting(_ failures: inout [String]) {
        let frequencies = [100.0, 1_000.0, 10_000.0]
        for sampleRate in [44_100.0, 48_000.0, 96_000.0] {
            for frequency in frequencies where frequency < sampleRate / 2 {
                for kind in [FrequencyWeightingFilter.Kind.a, .c] {
                    let measured = measuredGain(kind: kind, frequency: frequency, sampleRate: sampleRate)
                    let expected = independentAnalogGain(kind: kind, frequency: frequency)
                    if !measured.isFinite || abs(measured - expected) > 0.8 {
                        failures.append(String(
                            format: "%@ weighting %.0f Hz @ %.0f Hz was %.2f dB; analytic %.2f dB",
                            kind == .a ? "A" : "C", frequency, sampleRate, measured, expected
                        ))
                    }
                }
            }
        }
    }

    private static func testOneSecondLeqAndSignals(_ failures: inout [String]) {
        let sampleRate = 32_000
        let amplitude = 0.25
        let sine = (0..<sampleRate).map { index in
            Float(amplitude * sin(2 * Double.pi * 1_000 * Double(index) / Double(sampleRate)))
        }
        guard let sineResult = process(sine, sampleRate: sampleRate, chunks: [257]).last else {
            failures.append("One-second sine produced no completed interval")
            return
        }
        let expectedSineDB = 10 * log10(amplitude * amplitude / 2)
        assertClose(sineResult.lzeq1Second, expectedSineDB, tolerance: 1e-5,
                    name: "1 kHz Z-weighted sine Leq", failures: &failures)
        assertClose(sineResult.laeq1Second, expectedSineDB, tolerance: 0.15,
                    name: "1 kHz A-weighted sine Leq", failures: &failures)
        assertClose(sineResult.lceq1Second, expectedSineDB, tolerance: 0.15,
                    name: "1 kHz C-weighted sine Leq", failures: &failures)

        let constant = Array(repeating: Float(0.125), count: sampleRate)
        let constantResult = process(constant, sampleRate: sampleRate, chunks: [1_013]).last
        assertClose(constantResult?.lzeq1Second, 20 * log10(0.125), tolerance: 1e-6,
                    name: "constant-signal Z Leq", failures: &failures)

        var impulse = Array(repeating: Float.zero, count: sampleRate)
        impulse[0] = 0.5
        let impulseResult = process(impulse, sampleRate: sampleRate, chunks: [509]).last
        assertClose(
            impulseResult?.lzeq1Second,
            10 * log10(0.25 / Double(sampleRate)),
            tolerance: 1e-6,
            name: "impulse Z Leq",
            failures: &failures
        )

        let silence = Array(repeating: Float.zero, count: sampleRate)
        if process(silence, sampleRate: sampleRate, chunks: [128]).last?.lzeq1Second != nil {
            failures.append("Digital silence did not produce a missing/under-range Leq")
        }

        var generator = DeterministicNoise(seed: 0x1234_5678)
        var noise: [Float] = []
        noise.reserveCapacity(sampleRate)
        var noiseEnergy = 0.0
        for _ in 0..<sampleRate {
            let value = 0.2 * generator.nextWhite()
            noise.append(Float(value))
            noiseEnergy += value * value
        }
        let noiseResult = process(noise, sampleRate: sampleRate, chunks: [73, 2_048]).last
        assertClose(
            noiseResult?.lzeq1Second,
            10 * log10(noiseEnergy / Double(sampleRate)),
            tolerance: 1e-5,
            name: "deterministic white-noise Z Leq",
            failures: &failures
        )
    }

    private static func testBufferIndependence(_ failures: inout [String]) {
        let sampleRate = 32_000
        let samples = (0..<(sampleRate * 3)).map { index -> Float in
            let second = index / sampleRate
            let amplitude = [0.05, 0.2, 0.1][second]
            return Float(amplitude * sin(2 * Double.pi * 1_000 * Double(index) / Double(sampleRate)))
        }
        let singleFrames = process(samples, sampleRate: sampleRate, chunks: [samples.count])
        let variedFrames = process(samples, sampleRate: sampleRate, chunks: [1, 127, 509, 2_048])
        guard singleFrames.count == 3, singleFrames.count == variedFrames.count else {
            failures.append("Buffer-independent processing did not produce exactly three intervals")
            return
        }
        for index in singleFrames.indices where singleFrames[index] != variedFrames[index] {
            failures.append("DSP result depends on buffer boundaries at second \(index + 1)")
        }
    }

    private static func testPerSecondMaximaAndReset(_ failures: inout [String]) {
        let sampleRate = 32_000
        let samples = (0..<(sampleRate * 2)).map { index -> Float in
            let amplitude = index < sampleRate / 4 ? 0.5 : 0.05
            return Float(amplitude * sin(2 * Double.pi * 1_000 * Double(index) / Double(sampleRate)))
        }
        let processor = SPLProcessor(sampleRate: Double(sampleRate))
        let seconds = process(samples, processor: processor, chunks: [333])
        guard seconds.count == 2,
              let firstFast = seconds[0].lafMax1Second,
              let secondFast = seconds[1].lafMax1Second,
              let firstPeak = seconds[0].lcPeak1Second,
              let secondPeak = seconds[1].lcPeak1Second else {
            failures.append("Per-second Fast/Peak maxima were not produced")
            return
        }
        if firstFast - secondFast < 15 { failures.append("LAFmax,1s was not reset at the interval boundary") }
        if firstPeak - secondPeak < 15 { failures.append("LCpeak,1s was not reset at the interval boundary") }
        if seconds[1].lasMax1Second == nil { failures.append("LASmax,1s was not produced") }
        if seconds[1].lafMax != firstFast { failures.append("Session LAFmax did not retain the earlier maximum") }
        if seconds[1].lcPeak != firstPeak { failures.append("Session LCpeak did not retain the earlier maximum") }

        processor.reset()
        let resetSeconds = process(
            Array(repeating: Float.zero, count: sampleRate),
            processor: processor,
            chunks: [511]
        )
        guard let reset = resetSeconds.last else {
            failures.append("Reset processor did not produce a new interval")
            return
        }
        if reset.completedSecondCount != 1 || reset.processedFrameCount != UInt64(sampleRate) {
            failures.append("Processor reset did not reset frame/interval counters")
        }
        if reset.lafMax != nil || reset.lcPeak != nil {
            failures.append("Processor reset retained a previous maximum")
        }
    }

    private static func testBoundedSecondQueue(_ failures: inout [String]) {
        let sampleRate = 32_000
        let processor = SPLProcessor(sampleRate: Double(sampleRate))
        let samples = Array(repeating: Float(0.1), count: sampleRate * 10)
        _ = samples.withUnsafeBufferPointer {
            processor.process($0.baseAddress!, count: $0.count)
        }
        if processor.lostSecondIntervals != 2 {
            failures.append("Bounded DSP handoff did not report two overwritten intervals")
        }
        var retained = 0
        while processor.popCompletedSecond() != nil { retained += 1 }
        if retained != 8 { failures.append("Bounded DSP handoff retained \(retained), expected 8 intervals") }
    }

    private static func testDiscontinuityInvalidation(_ failures: inout [String]) {
        let sampleRate = 32_000
        let processor = SPLProcessor(sampleRate: Double(sampleRate))
        let partial = Array(repeating: Float(0.5), count: sampleRate / 2)
        _ = partial.withUnsafeBufferPointer {
            processor.process($0.baseAddress!, count: $0.count)
        }
        let discardedFrames = processor.invalidateTimeContinuity()
        if discardedFrames != UInt64(sampleRate / 2) {
            failures.append("Discontinuity did not report discarded partial frames")
        }
        let valid = Array(repeating: Float(0.05), count: sampleRate)
        let seconds = process(valid, processor: processor, chunks: [257])
        guard let result = seconds.last else {
            failures.append("Post-dropout interval was not produced")
            return
        }
        assertClose(
            result.lzeq1Second,
            20 * log10(0.05),
            tolerance: 1e-5,
            name: "post-dropout interval",
            failures: &failures
        )
        if result.processedFrameCount != UInt64(sampleRate + sampleRate / 2)
            || result.completedSecondCount != 1 {
            failures.append("Discontinuity did not preserve frame count while discarding partial time")
        }
        if result.laeq1 != nil || result.laeq10 != nil || result.laeq30 != nil {
            failures.append("A long-window value survived a measurement discontinuity")
        }
    }

    private static func testAcceleratedTwentyFourHours(_ failures: inout [String]) {
        let windowSeconds = 1_800
        var rolling = RollingEnergy(capacity: windowSeconds)
        var expectedTail = Array(repeating: 0.0, count: windowSeconds)
        var expectedTotal = 0.0
        for second in 0..<(24 * 60 * 60) {
            let energy = second.isMultiple(of: 17) ? 0.25 : 0.01
            let index = second % windowSeconds
            expectedTotal -= expectedTail[index]
            expectedTail[index] = energy
            expectedTotal += energy
            rolling.append(energy)
        }
        let expected = expectedTotal / Double(windowSeconds)
        if abs((rolling.average ?? -.infinity) - expected) > 1e-10 {
            failures.append("Accelerated 24-hour rolling-energy simulation drifted")
        }
        let maximumRate = UInt64(SPLProcessor.supportedSampleRateRange.upperBound)
        let framesAt192kHz = maximumRate * 24 * 60 * 60
        if framesAt192kHz != 16_588_800_000 {
            failures.append("24-hour frame-counter reference overflowed")
        }
    }

    private static func process(
        _ samples: [Float],
        sampleRate: Int,
        chunks: [Int]
    ) -> [RawMeterSnapshot] {
        process(samples, processor: SPLProcessor(sampleRate: Double(sampleRate)), chunks: chunks)
    }

    private static func process(
        _ samples: [Float],
        processor: SPLProcessor,
        chunks: [Int]
    ) -> [RawMeterSnapshot] {
        var results: [RawMeterSnapshot] = []
        samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            var chunkIndex = 0
            while offset < buffer.count {
                let count = min(chunks[chunkIndex % chunks.count], buffer.count - offset)
                _ = processor.process(baseAddress.advanced(by: offset), count: count)
                while let second = processor.popCompletedSecond() { results.append(second) }
                offset += count
                chunkIndex += 1
            }
        }
        return results
    }

    private static func latestSnapshot(
        afterProcessing samples: [Float],
        processor: SPLProcessor,
        chunks: [Int]
    ) -> RawMeterSnapshot? {
        var latest: RawMeterSnapshot?
        samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            var chunkIndex = 0
            while offset < buffer.count {
                let count = min(chunks[chunkIndex % chunks.count], buffer.count - offset)
                latest = processor.process(baseAddress.advanced(by: offset), count: count) ?? latest
                offset += count
                chunkIndex += 1
            }
        }
        return latest
    }

    private static func measuredGain(
        kind: FrequencyWeightingFilter.Kind,
        frequency: Double,
        sampleRate: Double
    ) -> Double {
        var filter = FrequencyWeightingFilter(kind: kind, sampleRate: sampleRate)
        let count = Int(sampleRate * 2)
        var inputEnergy = 0.0
        var outputEnergy = 0.0
        for index in 0..<count {
            let input = sin(2 * Double.pi * frequency * Double(index) / sampleRate)
            let output = filter.process(input)
            if index >= count / 2 {
                inputEnergy += input * input
                outputEnergy += output * output
            }
        }
        return 10 * log10(outputEnergy / inputEnergy)
    }

    private static func independentAnalogGain(
        kind: FrequencyWeightingFilter.Kind,
        frequency: Double
    ) -> Double {
        let f1 = 20.598997
        let f2 = 107.65265
        let f3 = 737.86223
        let f4 = 12_194.217
        let squared = frequency * frequency
        switch kind {
        case .a:
            let ratio = (f4 * f4 * squared * squared)
                / ((squared + f1 * f1)
                   * sqrt((squared + f2 * f2) * (squared + f3 * f3))
                   * (squared + f4 * f4))
            return 20 * log10(ratio) + 1.9997
        case .c:
            let ratio = (f4 * f4 * squared)
                / ((squared + f1 * f1) * (squared + f4 * f4))
            return 20 * log10(ratio) + 0.0619
        }
    }

    private static func assertClose(
        _ actual: Double?,
        _ expected: Double,
        tolerance: Double,
        name: String,
        failures: inout [String]
    ) {
        guard let actual, actual.isFinite, abs(actual - expected) <= tolerance else {
            failures.append("\(name) was \(String(describing: actual)); expected \(expected)")
            return
        }
    }

    private struct DeterministicNoise {
        var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func nextWhite() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let unit = Double(state >> 11) / Double(UInt64.max >> 11)
            return 2 * unit - 1
        }
    }
}
