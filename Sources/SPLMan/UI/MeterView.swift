import SwiftUI

struct MeterView: View {
    @ObservedObject var model: MeterModel

    var body: some View {
        GeometryReader { geometry in
            let columnWidth = geometry.size.width / CGFloat(model.settings.displayedMetrics.count + 1)

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
                    toggleRecording: model.toggleRecording,
                    openSettings: { model.isSettingsPresented = true },
                    columnWidth: columnWidth
                )
                    .frame(width: columnWidth)
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
    let toggleRecording: () -> Void
    let openSettings: () -> Void
    let columnWidth: CGFloat

    var body: some View {
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

            HStack(spacing: 12) {
                Button(action: toggleRecording) {
                    Image(systemName: recordingIcon)
                        .font(.system(size: isRecording ? 28 : 34, weight: .semibold))
                        .foregroundStyle(isRecording ? .red : .white)
                }
                .buttonStyle(SettingsButtonStyle())
                .disabled((!isRecording && !canStartRecording) || isPreparingRecording)
                .accessibilityLabel(isRecording ? L10n.text("Zastavit záznam") : L10n.text("Spustit záznam"))
                .help(isRecording ? L10n.text("Zastavit záznam") : L10n.text("Spustit záznam do CSV"))

                Button(action: openSettings) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 34, weight: .medium))
                }
                .buttonStyle(SettingsButtonStyle())
                .accessibilityLabel(L10n.text("Nastavení"))
                .help(L10n.text("Nastavení"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
        .foregroundStyle(.white)
    }

    private var recordingIcon: String {
        if isPreparingRecording { return "hourglass" }
        return isRecording ? "stop.fill" : "record.circle"
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 60, height: 60)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(white: configuration.isPressed ? 0.16 : 0.08))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(white: 0.3), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}
