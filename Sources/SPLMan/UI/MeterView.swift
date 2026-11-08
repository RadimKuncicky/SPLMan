import SwiftUI

struct MeterView: View {
    @ObservedObject var model: MeterModel

    var body: some View {
        GeometryReader { geometry in
            let columnWidth = geometry.size.width / CGFloat(model.settings.displayedMetrics.count + 1)

            ZStack(alignment: .leading) {
                if model.settings.spectrogram.displayMode.showsSpectrogram {
                    SpectrogramView(
                        columns: model.spectrogramColumns,
                        timelineNow: ProcessInfo.processInfo.systemUptime,
                        historyDuration: TimeInterval(
                            model.settings.spectrogram.historyDuration.rawValue
                        ),
                        opacity: model.settings.spectrogram.intensity.opacity,
                        palette: model.settings.spectrogram.palette,
                        upperLevelDB: model.settings.spectrogram.upperLevelDB,
                        dynamicRangeDB: model.settings.spectrogram.dynamicRangeDB,
                        calibrationOffsetDB: model.selectedCalibration?.offsetDB,
                        showFrequencyAxis: !model.settings.spectrogram.displayMode
                            .showsTransferFunction
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                }

                if model.settings.spectrogram.displayMode.showsTransferFunction {
                    TransferFunctionView(
                        analysis: model.transferFunctionAnalysis,
                        displayRangeDB: model.settings.spectrogram.transferFunctionRangeDB,
                        frequencyRange: model.settings.spectrogram.frequencyRange
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                }

                HStack(spacing: 0) {
                    ForEach(model.settings.displayedMetrics) { metric in
                        MetricColumn(
                            metric: metric,
                            value: model.snapshot.values[metric],
                            difference: difference(for: metric),
                            thresholds: model.settings.thresholds,
                            isLimitExceeded: isLimitExceeded(metric),
                            columnWidth: columnWidth
                        )
                        .frame(width: columnWidth)
                        .overlay(alignment: .trailing) {
                            Rectangle()
                                .fill(Color(white: 0.3))
                                .frame(width: 1)
                                .padding(.vertical, 42)
                        }
                    }

                    ClockColumn(
                        now: model.now,
                        isRecording: model.isRecording,
                        isPreparingRecording: model.isPreparingRecording,
                        canStartRecording: model.canStartRecording,
                        recordingStartedAt: model.recordingStartedAt,
                        operationalStatus: model.operationalStatus,
                        analysisDisplayMode: model.settings.spectrogram.displayMode,
                        transferFunctionDelaySeconds: model.transferFunctionAnalysis.curve?.delaySeconds,
                        toggleRecording: model.toggleRecording,
                        cycleAnalysisDisplayMode: model.cycleAnalysisDisplayMode,
                        openSettings: { model.isSettingsPresented = true },
                        columnWidth: columnWidth
                    )
                    .frame(width: columnWidth)
                }
            }
            .background(Color.black)
        }
        .frame(minWidth: 960, minHeight: 300)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.isSettingsPresented) {
            SettingsView(model: model)
        }
        .alert(L10n.text("Chyba záznamu"), isPresented: recordingErrorPresented) {
            Button(L10n.text("OK")) { model.dismissRecordingError() }
        } message: {
            Text(model.recordingError ?? L10n.text("Záznam se nepodařilo uložit."))
        }
    }

    private var recordingErrorPresented: Binding<Bool> {
        Binding(
            get: { model.recordingError != nil },
            set: { if !$0 { model.dismissRecordingError() } }
        )
    }

    private func difference(for metric: Metric) -> Double? {
        guard let aMetric = metric.matchingAMetric,
              let c = model.snapshot.values[metric],
              let a = model.snapshot.values[aMetric] else { return nil }
        return c - a
    }

    private func isLimitExceeded(_ metric: Metric) -> Bool {
        model.exceededLimits.contains(metric)
            || (metric == .lcPeak && model.exceededLimits.contains(.lcPeak1Second))
    }
}

private struct TransferFunctionView: View {
    @State private var retainedFrequencyScale: SpectrogramFrequencyScale?
    @State private var retainedFrequencyRange: SpectrogramFrequencyRange?

    let analysis: TransferFunctionAnalysis
    let displayRangeDB: Double
    let frequencyRange: SpectrogramFrequencyRange

    var body: some View {
        let curve = analysis.curve
        let automaticCenterDB = curve.map {
            $0.displayLowerDB / 2 + $0.displayUpperDB / 2
        } ?? 0
        let displayCenterDB = automaticCenterDB.isFinite ? automaticCenterDB : 0
        let displayHalfRangeDB = displayRangeDB.isFinite
            ? max(0.5, abs(displayRangeDB))
            : 12
        let displayLowerDB = displayCenterDB - displayHalfRangeDB
        let displayUpperDB = displayCenterDB + displayHalfRangeDB

        ZStack(alignment: .topLeading) {
            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                let graphHeight = max(1, size.height - 26)
                let levelSpan = displayUpperDB - displayLowerDB
                context.clip(
                    to: Path(
                        CGRect(x: 0, y: 0, width: size.width, height: graphHeight)
                    )
                )
                var referencePath = Path()
                let referenceStepDB = 6.0
                let referenceLineCount = Int(
                    (displayHalfRangeDB / referenceStepDB).rounded(.down)
                )
                for referenceIndex in -referenceLineCount...referenceLineCount {
                    let referenceOffsetDB = Double(referenceIndex) * referenceStepDB
                    let referenceLevelDB = displayCenterDB + referenceOffsetDB
                    let y = graphHeight * CGFloat(
                        (displayUpperDB - referenceLevelDB) / levelSpan
                    )
                    referencePath.move(to: CGPoint(x: 0, y: y))
                    referencePath.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(
                    referencePath,
                    with: .color(Color(red: 0, green: 0.2, blue: 0.65).opacity(0.8)),
                    lineWidth: 1
                )
            }
            .overlay {
                if let curve {
                    TransferFunctionTrace(
                        points: curve.points,
                        frequencyScale: curve.frequencyScale,
                        displayLowerDB: displayLowerDB,
                        displayUpperDB: displayUpperDB
                    )
                }
            }
            .overlay(alignment: .topLeading) {
                Text(String(format: "%+.0f dB", displayHalfRangeDB))
                    .font(.system(size: 9, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.62))
                    .padding(.leading, 4)
                    .padding(.top, 2)
            }
            .overlay(alignment: .bottomLeading) {
                Text(String(format: "%+.0f dB", -displayHalfRangeDB))
                    .font(.system(size: 9, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.62))
                    .padding(.leading, 4)
                    .padding(.bottom, 28)
            }
            .overlay(alignment: .bottom) {
                SpectrogramFrequencyAxis(scale: frequencyScale)
                    .frame(height: 26)
            }
        }
        .onAppear {
            retainFrequencyScale(analysis.curve?.frequencyScale)
        }
        .onChange(of: analysis.curve?.frequencyScale) { scale in
            retainFrequencyScale(scale)
        }
    }

    private var frequencyScale: SpectrogramFrequencyScale {
        if let curve = analysis.curve {
            return curve.frequencyScale
        }
        if retainedFrequencyRange == frequencyRange,
           let retainedFrequencyScale {
            return retainedFrequencyScale
        }
        return SpectrogramFrequencyScale(range: frequencyRange)
    }

    private func retainFrequencyScale(_ scale: SpectrogramFrequencyScale?) {
        guard let scale else { return }
        retainedFrequencyScale = scale
        retainedFrequencyRange = frequencyRange
    }
}

private struct SpectrogramView: View {
    @Environment(\.displayScale) private var displayScale

    let columns: [SpectrogramColumn]
    let timelineNow: TimeInterval
    let historyDuration: TimeInterval
    let opacity: Double
    let palette: SpectrogramPalette
    let upperLevelDB: Double
    let dynamicRangeDB: Double
    let calibrationOffsetDB: Double?
    var showFrequencyAxis = true

    var body: some View {
        ZStack(alignment: .bottom) {
            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                let scale = max(1, displayScale)
                let pixelHeight = Int(ceil(size.height * scale))
                let levelScale = SpectrogramLevelScale(
                    upperLevelDB: upperLevelDB,
                    dynamicRangeDB: dynamicRangeDB,
                    calibrationOffsetDB: calibrationOffsetDB
                )

                let runs = SpectrogramRasterizer.runs(
                    for: columns,
                    referenceUptime: timelineNow,
                    historyDuration: historyDuration,
                    pixelHeight: pixelHeight
                )
                for run in runs {
                    let rectangle = CGRect(
                        x: 0,
                        y: CGFloat(run.firstPixelIndex) / scale,
                        width: size.width,
                        height: CGFloat(run.pixelCount) / scale
                    )
                    context.fill(
                        Path(rectangle),
                        with: .linearGradient(
                            gradient(
                                for: run.levelsDBFS,
                                frequencies: run.frequencies,
                                frequencyScale: columns.last?.frequencyScale,
                                levelScale: levelScale
                            ),
                            startPoint: CGPoint(x: rectangle.minX, y: rectangle.midY),
                            endPoint: CGPoint(x: rectangle.maxX, y: rectangle.midY)
                        )
                    )
                }
            }

            if showFrequencyAxis,
               let frequencyScale = columns.last?.frequencyScale {
                SpectrogramFrequencyAxis(scale: frequencyScale)
                    .frame(height: 26)
            }
        }
    }

    private func gradient(
        for levelsDBFS: [Float],
        frequencies: [Double],
        frequencyScale: SpectrogramFrequencyScale?,
        levelScale: SpectrogramLevelScale
    ) -> Gradient {
        let positions = SpectrogramGradientLayout.stopPositions(
            frequencies: frequencies,
            valueCount: levelsDBFS.count,
            scale: frequencyScale
        )
        return Gradient(stops: positions.map { position in
            let value = levelScale.normalizedValue(
                for: Double(levelsDBFS[position.sourceIndex])
            )
            let color = value > 0
                ? palette.color(for: value).opacity(opacity)
                : Color.clear
            return Gradient.Stop(
                color: color,
                location: CGFloat(position.location)
            )
        })
    }
}

struct SpectrogramGradientStopPosition: Equatable {
    let sourceIndex: Int
    let location: Double
}

enum SpectrogramGradientLayout {
    static func stopPositions(
        frequencies: [Double],
        valueCount: Int,
        scale: SpectrogramFrequencyScale?
    ) -> [SpectrogramGradientStopPosition] {
        guard valueCount > 0 else { return [] }
        guard frequencies.count == valueCount,
              let scale else {
            let denominator = max(1, valueCount - 1)
            return (0..<valueCount).map {
                SpectrogramGradientStopPosition(
                    sourceIndex: $0,
                    location: Double($0) / Double(denominator)
                )
            }
        }

        let mapped = frequencies.enumerated().compactMap { index, frequency in
            scale.position(for: frequency).map {
                SpectrogramGradientStopPosition(sourceIndex: index, location: $0)
            }
        }
        guard mapped.count == valueCount,
              zip(mapped, mapped.dropFirst()).allSatisfy({ $0.location < $1.location }) else {
            let denominator = max(1, valueCount - 1)
            return (0..<valueCount).map {
                SpectrogramGradientStopPosition(
                    sourceIndex: $0,
                    location: Double($0) / Double(denominator)
                )
            }
        }

        var stops = mapped
        if let first = mapped.first, first.location > 0 {
            stops.insert(
                SpectrogramGradientStopPosition(sourceIndex: first.sourceIndex, location: 0),
                at: 0
            )
        }
        if let last = mapped.last, last.location < 1 {
            stops.append(
                SpectrogramGradientStopPosition(sourceIndex: last.sourceIndex, location: 1)
            )
        }
        return stops
    }
}

private extension SpectrogramPalette {
    func color(for energy: Double) -> Color {
        let energy = min(1, max(0, energy))
        switch self {
        case .current:
            if energy < 0.5 {
                let fraction = energy * 2
                return Color(
                    red: 0.01,
                    green: 0.12 + 0.68 * fraction,
                    blue: 0.30 + 0.55 * fraction
                )
            }
            let fraction = (energy - 0.5) * 2
            return Color(
                red: 0.02 + 0.98 * fraction,
                green: 0.80 + 0.15 * fraction,
                blue: 0.85 * (1 - fraction)
            )

        case .rgb:
            if energy < 0.5 {
                let fraction = energy * 2
                return Color(red: 0, green: fraction, blue: 1 - fraction)
            }
            let fraction = (energy - 0.5) * 2
            return Color(red: fraction, green: 1 - fraction, blue: 0)

        case .smaartInspired:
            if energy < 0.2 {
                let fraction = energy * 5
                return Color(
                    red: 0.10 * (1 - fraction),
                    green: 0.04 + 0.12 * fraction,
                    blue: 0.24 + 0.66 * fraction
                )
            }
            if energy < 0.4 {
                let fraction = (energy - 0.2) * 5
                return Color(
                    red: 0,
                    green: 0.16 + 0.74 * fraction,
                    blue: 0.90 + 0.10 * fraction
                )
            }
            if energy < 0.6 {
                let fraction = (energy - 0.4) * 5
                return Color(
                    red: 0.05 * fraction,
                    green: 0.90 + 0.10 * fraction,
                    blue: 1 - 0.95 * fraction
                )
            }
            if energy < 0.8 {
                let fraction = (energy - 0.6) * 5
                return Color(
                    red: 0.05 + 0.95 * fraction,
                    green: 1,
                    blue: 0.05 * (1 - fraction)
                )
            }
            let fraction = (energy - 0.8) * 5
            return Color(red: 1, green: 1 - fraction, blue: 0)
        }
    }
}

private struct SpectrogramFrequencyAxis: View {
    private static let labelWidth: CGFloat = 44
    private static let minimumTickSpacing: CGFloat = 52
    private static let preferredFrequencies = [
        20.0, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000
    ]

    let scale: SpectrogramFrequencyScale

    var body: some View {
        GeometryReader { geometry in
            let ticks = ticks(for: geometry.size.width)
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0.5))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: 0.5))
                    for tick in ticks {
                        let x = geometry.size.width * CGFloat(tick.position)
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: 5))
                    }
                }
                .stroke(Color.white.opacity(0.32), lineWidth: 0.5)

                ForEach(ticks, id: \.frequency) { tick in
                    Text(Self.label(for: tick.frequency))
                        .font(.system(size: 9, weight: .regular, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.72))
                        .frame(width: Self.labelWidth)
                        .position(
                            x: min(
                                geometry.size.width - Self.labelWidth / 2,
                                max(
                                    Self.labelWidth / 2,
                                    geometry.size.width * CGFloat(tick.position)
                                )
                            ),
                            y: 14
                        )
                }
            }
            .background(Color.black.opacity(0.28))
        }
    }

    private func ticks(for width: CGFloat) -> [(frequency: Double, position: Double)] {
        guard width > 0 else { return [] }
        let endpoints = [scale.lowerFrequency, scale.upperFrequency]
        let candidates = (endpoints + Self.preferredFrequencies)
            .filter { $0 >= scale.lowerFrequency && $0 <= scale.upperFrequency }
            .sorted()
            .reduce(into: [Double]()) { values, frequency in
                if values.last.map({ abs($0 - frequency) > 0.01 }) ?? true {
                    values.append(frequency)
                }
            }
        let positioned = candidates.compactMap { frequency -> (Double, Double)? in
            scale.position(for: frequency).map { (frequency, $0) }
        }
        guard positioned.count > 2 else { return positioned }

        var selected = [positioned[0]]
        for tick in positioned.dropFirst().dropLast() {
            let x = width * CGFloat(tick.1)
            let previousX = width * CGFloat(selected[selected.count - 1].1)
            let upperDistance = width * CGFloat(1 - tick.1)
            if x - previousX >= Self.minimumTickSpacing,
               upperDistance >= Self.minimumTickSpacing {
                selected.append(tick)
            }
        }
        selected.append(positioned[positioned.count - 1])
        return selected
    }

    private static func label(for frequency: Double) -> String {
        if frequency >= 1_000 {
            let kilohertz = frequency / 1_000
            return kilohertz.rounded() == kilohertz
                ? String(format: "%.0f kHz", kilohertz)
                : String(format: "%.1f kHz", kilohertz)
        }
        return String(format: "%.0f Hz", frequency)
    }
}

private struct MetricColumn: View {
    let metric: Metric
    let value: Double?
    let difference: Double?
    let thresholds: VisualThresholds
    let isLimitExceeded: Bool
    let columnWidth: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            Text(metric.title)
                .font(.system(size: MeterTypography.metricTitleSize(for: columnWidth), weight: .medium))
                .minimumScaleFactor(0.8)
                .lineLimit(1)

            Spacer(minLength: 0)

            metricValueText
                .fontWidth(.condensed)
                .monospacedDigit()
                .minimumScaleFactor(0.75)
                .lineLimit(1)
                .foregroundStyle(valueColor)

            Text("dB")
                .font(.system(size: MeterTypography.metricUnitSize(for: columnWidth), weight: .medium))

            if metric.matchingAMetric != nil {
                Text(difference.map { String(format: "C−A  %+.1f dB", $0) } ?? "C−A  —")
                    .font(.system(size: MeterTypography.metricDifferenceSize(for: columnWidth), weight: .regular))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
            } else {
                Text(" ").font(.system(size: MeterTypography.metricDifferenceSize(for: columnWidth)))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, MeterTypography.horizontalPadding(for: columnWidth))
        .padding(.vertical, 32)
        .foregroundStyle(.white)
    }

    private var valueColor: Color {
        guard let value else { return Color(white: 0.5) }
        if isLimitExceeded { return .red }
        let range = thresholds.range(for: metric)
        guard value > range.lowerBound else { return .white }
        guard value < range.upperBound else { return .yellow }
        let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return Color(red: 1, green: 1, blue: 1 - fraction)
    }

    private var metricValueText: Text {
        guard let value else {
            return Text("—")
                .font(.system(size: MeterTypography.metricValueSize(for: columnWidth), weight: .semibold))
        }

        let formattedValue = String(format: "%.1f", value)
        let fractionStart = formattedValue.index(formattedValue.endIndex, offsetBy: -2)
        let integerPart = formattedValue[..<fractionStart]
        let fractionPart = formattedValue[fractionStart...]

        return Text(integerPart)
            .font(.system(size: MeterTypography.metricValueSize(for: columnWidth), weight: .semibold))
            + Text(fractionPart)
            .font(.system(size: MeterTypography.metricFractionSize(for: columnWidth), weight: .semibold))
    }
}

private struct ClockColumn: View {
    let now: Date
    let isRecording: Bool
    let isPreparingRecording: Bool
    let canStartRecording: Bool
    let recordingStartedAt: Date?
    let operationalStatus: MeterOperationalStatus
    let analysisDisplayMode: AnalysisDisplayMode
    let transferFunctionDelaySeconds: TimeInterval?
    let toggleRecording: () -> Void
    let cycleAnalysisDisplayMode: () -> Void
    let openSettings: () -> Void
    let columnWidth: CGFloat

    var body: some View {
        let buttonSideLength = MeterControls.buttonSideLength(for: columnWidth)

        VStack(spacing: 16) {
            Text(now.formatted(.dateTime.weekday(.wide)))
                .font(.system(size: MeterTypography.clockWeekdaySize(for: columnWidth), weight: .regular))
                .foregroundStyle(.secondary)

            Text(now.formatted(.dateTime.day().month().year()))
                .font(.system(size: MeterTypography.clockDateSize(for: columnWidth), weight: .medium))
                .minimumScaleFactor(0.8)
                .lineLimit(1)

            Divider().background(Color(white: 0.3))

            Text(now.formatted(.dateTime.hour().minute().second()))
                .font(.system(size: MeterTypography.clockTimeSize(for: columnWidth), weight: .semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.8)
                .lineLimit(1)

            Divider().background(Color(white: 0.3))

            HStack(spacing: 7) {
                Circle()
                    .fill(.red)
                    .frame(width: 9, height: 9)
                Text(recordingElapsed)
                    .font(.system(size: MeterTypography.recordingStatusSize(for: columnWidth), weight: .medium, design: .monospaced))
                    .monospacedDigit()
            }
            .frame(height: 22)
            .opacity(isRecording ? 1 : 0)
            .accessibilityHidden(!isRecording)
            .accessibilityLabel(L10n.format("Záznam aktivní, uplynulo %@", recordingElapsed))

            Text(operationalStatus.title)
                .font(.system(size: MeterTypography.recordingStatusSize(for: columnWidth), weight: .semibold))
                .foregroundStyle(operationalStatusColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(height: 18)
                .accessibilityLabel(L10n.format("Stav měření: %@", operationalStatus.title))

            VStack(spacing: 5) {
                HStack(spacing: MeterControls.buttonSpacing(for: columnWidth)) {
                    Button(action: toggleRecording) {
                        Image(systemName: recordingIcon)
                            .font(
                                .system(
                                    size: MeterControls.recordingIconSize(
                                        buttonSideLength: buttonSideLength,
                                        isRecording: isRecording
                                    ),
                                    weight: .semibold
                                )
                            )
                            .foregroundStyle(isRecording ? .red : .white)
                    }
                    .buttonStyle(SettingsButtonStyle(sideLength: buttonSideLength))
                    .disabled((!isRecording && !canStartRecording) || isPreparingRecording)
                    .accessibilityLabel(isRecording ? L10n.text("Zastavit záznam") : L10n.text("Spustit záznam"))
                    .help(isRecording ? L10n.text("Zastavit záznam") : L10n.text("Spustit záznam do CSV"))

                    Button(action: cycleAnalysisDisplayMode) {
                        VStack(spacing: MeterControls.analysisContentSpacing(for: buttonSideLength)) {
                            Image(systemName: analysisDisplayIcon)
                                .font(
                                    .system(
                                        size: MeterControls.analysisIconSize(
                                            buttonSideLength: buttonSideLength
                                        ),
                                        weight: .medium
                                    )
                                )
                            Text(analysisDisplayShortTitle)
                                .font(
                                    .system(
                                        size: MeterControls.analysisLabelSize(
                                            buttonSideLength: buttonSideLength
                                        ),
                                        weight: .semibold
                                    )
                                )
                        }
                    }
                    .buttonStyle(SettingsButtonStyle(sideLength: buttonSideLength))
                    .accessibilityLabel(analysisDisplayMode.title)
                    .accessibilityHint(
                        L10n.text("Přepnout na") + " " + analysisDisplayMode.next.title
                    )
                    .help(
                        analysisDisplayMode.title + " → " + analysisDisplayMode.next.title
                    )

                    Button(action: openSettings) {
                        Image(systemName: "gearshape.fill")
                            .font(
                                .system(
                                    size: MeterControls.settingsIconSize(
                                        buttonSideLength: buttonSideLength
                                    ),
                                    weight: .medium
                                )
                            )
                    }
                    .buttonStyle(SettingsButtonStyle(sideLength: buttonSideLength))
                    .accessibilityLabel(L10n.text("Nastavení"))
                    .help(L10n.text("Nastavení"))
                }

                if analysisDisplayMode.showsTransferFunction {
                    Text(verbatim: "AutoDelay: \(formattedTransferFunctionDelay)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, MeterControls.horizontalPadding(for: columnWidth))
        .padding(.vertical, 24)
        .foregroundStyle(.white)
    }

    private var recordingIcon: String {
        if isPreparingRecording { return "hourglass" }
        return isRecording ? "stop.fill" : "record.circle"
    }

    private var analysisDisplayIcon: String {
        switch analysisDisplayMode {
        case .spectrogram: "waveform"
        case .transferFunction: "waveform.path.ecg"
        case .combined: "waveform.path.ecg"
        case .none: "eye.slash"
        }
    }

    private var analysisDisplayShortTitle: String {
        switch analysisDisplayMode {
        case .spectrogram: "SPEC"
        case .transferFunction: "TF"
        case .combined: "TF+SPEC"
        case .none: "—"
        }
    }

    private var formattedTransferFunctionDelay: String {
        guard let transferFunctionDelaySeconds,
              transferFunctionDelaySeconds.isFinite else { return "—" }
        return String(format: "%.1f ms", transferFunctionDelaySeconds * 1_000)
    }

    private var recordingElapsed: String {
        guard let recordingStartedAt else { return "REC 00:00:00" }
        let seconds = max(0, Int(now.timeIntervalSince(recordingStartedAt)))
        return String(
            format: "REC %02d:%02d:%02d",
            seconds / 3_600,
            (seconds / 60) % 60,
            seconds % 60
        )
    }

    private var operationalStatusColor: Color {
        switch operationalStatus {
        case .ready: .secondary
        case .notice: .yellow
        case .warning, .storageError: .red
        }
    }
}

private enum MeterControls {
    static func horizontalPadding(for columnWidth: CGFloat) -> CGFloat {
        clamped(columnWidth * 0.067, minimum: 4, maximum: 16)
    }

    static func buttonSpacing(for columnWidth: CGFloat) -> CGFloat {
        clamped(columnWidth * 0.05, minimum: 4, maximum: 12)
    }

    static func buttonSideLength(for columnWidth: CGFloat) -> CGFloat {
        let padding = horizontalPadding(for: columnWidth)
        let spacing = buttonSpacing(for: columnWidth)
        let availableWidth = max(0, columnWidth - 2 * padding - 2 * spacing)
        return max(1, min(72, columnWidth * 0.25, availableWidth / 3))
    }

    static func recordingIconSize(
        buttonSideLength: CGFloat,
        isRecording: Bool
    ) -> CGFloat {
        buttonSideLength * (isRecording ? 0.47 : 0.57)
    }

    static func analysisIconSize(buttonSideLength: CGFloat) -> CGFloat {
        buttonSideLength * 0.4
    }

    static func analysisLabelSize(buttonSideLength: CGFloat) -> CGFloat {
        buttonSideLength * 0.13
    }

    static func analysisContentSpacing(for buttonSideLength: CGFloat) -> CGFloat {
        buttonSideLength * 0.033
    }

    static func settingsIconSize(buttonSideLength: CGFloat) -> CGFloat {
        buttonSideLength * 0.57
    }

    static func cornerRadius(for buttonSideLength: CGFloat) -> CGFloat {
        buttonSideLength * 0.2
    }

    private static func clamped(
        _ value: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        min(maximum, max(minimum, value))
    }
}

private enum MeterTypography {
    static func horizontalPadding(for columnWidth: CGFloat) -> CGFloat {
        clamped(columnWidth * 0.04, minimum: 6, maximum: 18)
    }

    static func metricTitleSize(for columnWidth: CGFloat) -> CGFloat {
        clamped(columnWidth * 0.10, minimum: 12, maximum: 36)
    }

    static func metricValueSize(for columnWidth: CGFloat) -> CGFloat {
        clamped(columnWidth * 0.44, minimum: 32, maximum: 176)
    }

    static func metricFractionSize(for columnWidth: CGFloat) -> CGFloat {
        clamped(columnWidth * 0.36, minimum: 26, maximum: 144)
    }

    static func metricUnitSize(for columnWidth: CGFloat) -> CGFloat {
        clamped(columnWidth * 0.075, minimum: 12, maximum: 32)
    }

    static func metricDifferenceSize(for columnWidth: CGFloat) -> CGFloat {
        clamped(columnWidth * 0.05, minimum: 10, maximum: 21)
    }

    static func clockWeekdaySize(for columnWidth: CGFloat) -> CGFloat {
        clamped(columnWidth * 0.06, minimum: 12, maximum: 24)
    }

    static func clockDateSize(for columnWidth: CGFloat) -> CGFloat {
        clamped(columnWidth * 0.075, minimum: 14, maximum: 31)
    }

    static func clockTimeSize(for columnWidth: CGFloat) -> CGFloat {
        clamped(columnWidth * 0.10, minimum: 18, maximum: 41)
    }

    static func recordingStatusSize(for columnWidth: CGFloat) -> CGFloat {
        clamped(columnWidth * 0.045, minimum: 10, maximum: 17)
    }

    private static func clamped(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(maximum, max(minimum, value))
    }
}

private struct SettingsButtonStyle: ButtonStyle {
    let sideLength: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        let cornerRadius = MeterControls.cornerRadius(for: sideLength)

        configuration.label
            .frame(width: sideLength, height: sideLength)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(white: configuration.isPressed ? 0.16 : 0.08))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color(white: 0.3), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
