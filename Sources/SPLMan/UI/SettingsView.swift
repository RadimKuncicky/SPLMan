import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var model: MeterModel
    @Environment(\.dismiss) private var dismiss
    @State private var draggedMetric: Metric?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L10n.text("Nastavení SPL"))
                    .font(.title.bold())
                Spacer()
                Button(L10n.text("Hotovo")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox(L10n.text("Zvukový vstup")) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Picker(L10n.text("Zařízení"), selection: deviceBinding) {
                                    Text(L10n.text("Nevybráno")).tag("")
                                    ForEach(model.devices) { device in
                                        Text(device.name).tag(device.uid)
                                    }
                                }
                                Button(L10n.text("Obnovit")) { model.refreshDevices() }
                            }

                            if let device = model.selectedDevice {
                                Picker(L10n.text("Kanál"), selection: channelBinding) {
                                    ForEach(0..<device.inputChannelCount, id: \.self) { channel in
                                        Text(L10n.format("Kanál %d", Int32(channel + 1))).tag(channel)
                                    }
                                }
                            }

                            Text(model.status)
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            HStack {
                                Button(L10n.text("Spustit vstup")) { model.startSelectedInput() }
                                    .disabled(model.settings.input == nil || model.isRunning)
                                Button(L10n.text("Kalibrovat na 94 dB")) { model.beginCalibration() }
                                    .disabled(!model.isRunning)
                                if let progress = model.calibrationProgress {
                                    ProgressView(value: progress)
                                        .frame(width: 170)
                                } else if let calibration = model.selectedCalibration {
                                    Text(L10n.format("Kalibrováno %@", calibration.calibratedAt.formatted(date: .abbreviated, time: .shortened)))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(6)
                    }

                    GroupBox(L10n.text("Měřicí relace")) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField(L10n.text("Název akce"), text: $model.recordingMetadata.eventName)
                            TextField(L10n.text("Místo měření"), text: $model.recordingMetadata.location)
                            TextField(L10n.text("Identifikace mikrofonu"), text: $model.recordingMetadata.microphoneID)
                            TextField(L10n.text("Poznámka"), text: $model.recordingMetadata.note, axis: .vertical)
                                .lineLimit(2...4)
                            Text(L10n.text("Metadata se uloží do následující měřicí relace."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .disabled(model.isRecording || model.isPreparingRecording)
                    }

                    GroupBox(L10n.text("Zobrazená měření")) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading) {
                            ForEach(Metric.allCases) { metric in
                                Toggle(metric.title, isOn: metricBinding(metric))
                            }
                        }
                        .padding(6)
                    }

                    GroupBox(L10n.text("Analýza")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker(
                                L10n.text("Zobrazení analýzy"),
                                selection: analysisDisplayModeBinding
                            ) {
                                ForEach(AnalysisDisplayMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }

                            Picker(
                                L10n.text("Referenční kanál"),
                                selection: referenceChannelBinding
                            ) {
                                Text(L10n.text("Žádný")).tag(Int?.none)
                                if let device = model.selectedDevice,
                                   let measurementChannel = model.settings.input?.channel {
                                    ForEach(
                                        (0..<device.inputChannelCount).filter {
                                            $0 != measurementChannel
                                        },
                                        id: \.self
                                    ) { channel in
                                        Text(L10n.format("Kanál %d", Int32(channel + 1)))
                                            .tag(Optional(channel))
                                    }
                                }
                            }
                            .disabled(
                                (model.selectedDevice?.inputChannelCount ?? 0) < 2
                                    || !model.canReconfigureAnalysisInput
                            )

                            if model.settings.spectrogram.displayMode.showsTransferFunction {
                                numericField(
                                    title: L10n.text("Svislý rozsah TF"),
                                    prefix: "±",
                                    value: transferFunctionRangeBinding,
                                    unit: "dB",
                                    validation: SpectrogramSettings
                                        .validatedTransferFunctionRange
                                )

                                Text(L10n.text("Křivka používá průběžné zarovnání impulsní odezvy a frekvenčně závislé časové okno."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                Picker(
                                    L10n.text("Frekvenční rozsah"),
                                    selection: $model.settings.spectrogram.frequencyRange
                                ) {
                                    ForEach(SpectrogramFrequencyRange.allCases) { range in
                                        Text(range.title).tag(range)
                                    }
                                }

                                Picker(
                                    L10n.text("Historie"),
                                    selection: $model.settings.spectrogram.historyDuration
                                ) {
                                    ForEach(SpectrogramHistoryDuration.allCases) { duration in
                                        Text(duration.title).tag(duration)
                                    }
                                }

                                Picker(
                                    L10n.text("Intenzita"),
                                    selection: $model.settings.spectrogram.intensity
                                ) {
                                    ForEach(SpectrogramIntensity.allCases) { intensity in
                                        Text(intensity.title).tag(intensity)
                                    }
                                }

                                Picker(
                                    L10n.text("Barevná stupnice"),
                                    selection: $model.settings.spectrogram.palette
                                ) {
                                    ForEach(SpectrogramPalette.allCases) { palette in
                                        Text(palette.title).tag(palette)
                                    }
                                }

                                spectrogramLevelField(
                                    title: L10n.text("Horní hranice"),
                                    value: spectrogramUpperLevelBinding,
                                    unit: "dB SPL",
                                    validation: SpectrogramSettings.validatedUpperLevel
                                )
                                spectrogramLevelField(
                                    title: L10n.text("Dynamický rozsah"),
                                    value: spectrogramDynamicRangeBinding,
                                    unit: "dB",
                                    validation: SpectrogramSettings.validatedDynamicRange
                                )

                                Text(L10n.text("Po kalibraci barvy zobrazují přibližnou nekorigovanou hladinu (Z); bez kalibrace používají relativní stupnici dBFS."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(L10n.text("Nízké frekvence používají jednotlivé FFT biny normalizované na šířku 1/24 oktávy; vyšší frekvence používají integrovaná 1/24oktávová pásma."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if model.selectedCalibration == nil {
                                    Text(L10n.text("Bez kalibrace končí stupnice na 0 dBFS; nastavená horní hranice SPL se použije po kalibraci."))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(L10n.text("Skutečný horní limit závisí na vzorkovací frekvenci vstupu."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(6)
                    }

                    GroupBox(L10n.text("Pořadí zobrazených měření")) {
                        List {
                            ForEach(model.settings.displayedMetrics) { metric in
                                metricOrderRow(metric)
                                    .onDrop(
                                        of: [UTType.plainText.identifier],
                                        delegate: MetricDropDelegate(
                                            targetMetric: metric,
                                            draggedMetric: $draggedMetric,
                                            move: model.moveMetric
                                        )
                                    )
                            }
                        }
                        .listStyle(.bordered)
                        .frame(height: metricOrderListHeight)
                        .padding(6)
                    }

                    GroupBox(L10n.text("Barevné upozornění")) {
                        VStack(alignment: .leading, spacing: 8) {
                            thresholdRow(
                                title: L10n.text("A: přechod / žlutá"),
                                start: $model.settings.thresholds.aTransitionStart,
                                yellow: $model.settings.thresholds.aYellow
                            )
                            thresholdRow(
                                title: L10n.text("C: přechod / žlutá"),
                                start: $model.settings.thresholds.cTransitionStart,
                                yellow: $model.settings.thresholds.cYellow
                            )
                            Text(L10n.text("Barvy jsou pouze orientační vizuální upozornění pro live sound."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(6)
                    }

                    GroupBox(L10n.text("Alarmy měření")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(L10n.text("Zaznamenávat překročení limitů"), isOn: $model.alarmSettings.isEnabled)
                            thresholdField(
                                title: "LAeq 30 min",
                                value: $model.alarmSettings.laeq30MinuteLimit
                            )
                            thresholdField(
                                title: "LCpeak",
                                value: $model.alarmSettings.lcPeakLimit
                            )
                            Text(L10n.text("Výchozí hodnoty jsou orientační. Neprokazují shodu měření s DIN 15905-5."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(6)
                    }

                    GroupBox(L10n.text("Historie záznamů")) {
                        if model.recordingHistory.isEmpty {
                            Text(L10n.text("Zatím nebyl vytvořen žádný záznam."))
                                .foregroundStyle(.secondary)
                                .padding(6)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(model.recordingHistory) { entry in
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack(spacing: 10) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(entry.eventName.isEmpty ? L10n.text("Měření") : entry.eventName)
                                                    .lineLimit(1)
                                                Text(historyDetail(entry))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                            Spacer()
                                            Text(entry.state.title)
                                                .font(.caption)
                                                .foregroundStyle(entry.state == .failed ? .red : .secondary)
                                            Button(model.selectedEventSessionID == entry.id ? L10n.text("Skrýt události") : L10n.text("Události")) {
                                                model.toggleRecordingEvents(entry)
                                            }
                                            Button(L10n.text("Zobrazit")) { model.revealRecording(entry) }
                                        }
                                        if model.selectedEventSessionID == entry.id {
                                            recordingEvents
                                        }
                                    }
                                    .padding(.vertical, 6)
                                    if entry.id != model.recordingHistory.last?.id { Divider() }
                                }
                            }
                            .padding(6)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 760, height: 480)
    }

    private var deviceBinding: Binding<String> {
        Binding(
            get: { model.settings.input?.deviceUID ?? "" },
            set: { if !$0.isEmpty { model.selectDevice(uid: $0) } }
        )
    }

    private var channelBinding: Binding<Int> {
        Binding(
            get: { model.settings.input?.channel ?? 0 },
            set: model.selectChannel
        )
    }

    private func metricBinding(_ metric: Metric) -> Binding<Bool> {
        Binding(
            get: { model.settings.displayedMetrics.contains(metric) },
            set: { _ in model.toggleMetric(metric) }
        )
    }

    private var metricOrderListHeight: CGFloat {
        CGFloat(model.settings.displayedMetrics.count * 34 + 4)
    }

    private func metricOrderRow(_ metric: Metric) -> some View {
        let index = model.settings.displayedMetrics.firstIndex(of: metric) ?? 0
        let lastIndex = model.settings.displayedMetrics.count - 1

        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .help(L10n.text("Přetažením změňte pořadí"))
                .onDrag {
                    draggedMetric = metric
                    return NSItemProvider(object: metric.rawValue as NSString)
                }

            Text(metric.title)
            Spacer()

            Button {
                model.moveMetric(metric, by: -1)
            } label: {
                Image(systemName: "arrow.left")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help(L10n.text("Posunout vlevo"))
            .accessibilityLabel(L10n.format("Posunout %@ vlevo", metric.title))

            Button {
                model.moveMetric(metric, by: 1)
            } label: {
                Image(systemName: "arrow.right")
            }
            .buttonStyle(.borderless)
            .disabled(index == lastIndex)
            .help(L10n.text("Posunout vpravo"))
            .accessibilityLabel(L10n.format("Posunout %@ vpravo", metric.title))
        }
        .contentShape(Rectangle())
    }

    private func thresholdRow(
        title: String,
        start: Binding<Double>,
        yellow: Binding<Double>
    ) -> some View {
        HStack {
            Text(title).frame(width: 210, alignment: .leading)
            NumericTextField(value: start)
                .frame(width: 55)
            Text("dB →")
            NumericTextField(value: yellow)
                .frame(width: 55)
            Text("dB")
        }
    }

    private var spectrogramUpperLevelBinding: Binding<Double> {
        Binding(
            get: { model.settings.spectrogram.upperLevelDB },
            set: {
                model.settings.spectrogram.upperLevelDB = SpectrogramSettings
                    .validatedUpperLevel($0)
            }
        )
    }

    private var analysisDisplayModeBinding: Binding<AnalysisDisplayMode> {
        Binding(
            get: { model.settings.spectrogram.displayMode },
            set: model.setAnalysisDisplayMode
        )
    }

    private var referenceChannelBinding: Binding<Int?> {
        Binding(
            get: { model.settings.spectrogram.referenceChannel },
            set: model.selectReferenceChannel
        )
    }

    private var spectrogramDynamicRangeBinding: Binding<Double> {
        Binding(
            get: { model.settings.spectrogram.dynamicRangeDB },
            set: {
                model.settings.spectrogram.dynamicRangeDB = SpectrogramSettings
                    .validatedDynamicRange($0)
            }
        )
    }

    private var transferFunctionRangeBinding: Binding<Double> {
        Binding(
            get: { model.settings.spectrogram.transferFunctionRangeDB },
            set: {
                model.settings.spectrogram.transferFunctionRangeDB = SpectrogramSettings
                    .validatedTransferFunctionRange($0)
            }
        )
    }

    private func spectrogramLevelField(
        title: String,
        value: Binding<Double>,
        unit: String,
        validation: @escaping (Double) -> Double
    ) -> some View {
        numericField(
            title: title,
            value: value,
            unit: unit,
            validation: validation
        )
    }

    private func numericField(
        title: String,
        prefix: String? = nil,
        value: Binding<Double>,
        unit: String,
        validation: @escaping (Double) -> Double = { $0 }
    ) -> some View {
        HStack {
            Text(title).frame(width: 210, alignment: .leading)
            if let prefix { Text(prefix) }
            NumericTextField(value: value, validation: validation)
                .frame(width: 55)
            Text(unit)
        }
    }

    private func thresholdField(title: String, value: Binding<Double>) -> some View {
        numericField(title: title, value: value, unit: "dB")
    }

    private func historyDetail(_ entry: RecordingHistoryEntry) -> String {
        let date = entry.startedAt.formatted(date: .abbreviated, time: .shortened)
        return entry.location.isEmpty ? date : "\(date) · \(entry.location)"
    }

    @ViewBuilder
    private var recordingEvents: some View {
        if model.isEventHistoryLoading {
            ProgressView(L10n.text("Načítám události…"))
                .controlSize(.small)
        } else if let error = model.eventHistoryError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        } else if model.selectedRecordingEvents.isEmpty {
            Text(L10n.text("Relace neobsahuje žádné události."))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if model.isEventHistoryTruncated {
                    Text(L10n.text("Zobrazeno posledních 100 událostí."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.selectedRecordingEvents) { event in
                    HStack(alignment: .top, spacing: 8) {
                        Text(event.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 72, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title)
                                .font(.caption.weight(.medium))
                            if !event.metadataDetail.isEmpty {
                                Text(event.metadataDetail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct NumericTextField: View {
    @Binding var value: Double
    let validation: (Double) -> Double

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    init(
        value: Binding<Double>,
        validation: @escaping (Double) -> Double = { $0 }
    ) {
        _value = value
        self.validation = validation
    }

    var body: some View {
        TextField("", text: $draft)
            .focused($isFocused)
            .onAppear { draft = formatted(value) }
            .onSubmit(commit)
            .onChange(of: isFocused) { focused in
                if !focused { commit() }
            }
            .onChange(of: value) { newValue in
                if !isFocused { draft = formatted(newValue) }
            }
            .onDisappear(perform: commit)
    }

    private func commit() {
        if let parsedValue = parsed(draft), parsedValue.isFinite {
            let committedValue = validation(parsedValue.rounded())
            if committedValue != value { value = committedValue }
        }
        draft = formatted(value)
    }

    private func parsed(_ text: String) -> Double? {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.isLenient = false
        return formatter.number(from: text)?.doubleValue
            ?? Double(text.replacingOccurrences(of: ",", with: "."))
    }

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
}

private struct MetricDropDelegate: DropDelegate {
    let targetMetric: Metric
    @Binding var draggedMetric: Metric?
    let move: (Metric, Metric) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedMetric, draggedMetric != targetMetric else { return }
        move(draggedMetric, targetMetric)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedMetric = nil
        return true
    }
}
