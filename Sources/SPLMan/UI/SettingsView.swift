import SwiftUI
import UniformTypeIdentifiers

/// Settings are laid out for the wide, low 1920 × 480 meter display:
/// a sidebar with sections on the left and two-column content on the right,
/// so each section fits the available height without long vertical scrolling.
enum SettingsSection: String, CaseIterable, Identifiable {
    case input
    case display
    case analysis
    case mixer
    case wireless
    case alerts
    case recording

    var id: String { rawValue }

    var title: String {
        switch self {
        case .input: L10n.text("Vstup a kalibrace")
        case .display: L10n.text("Zobrazená měření")
        case .analysis: L10n.text("Analýza")
        case .mixer: L10n.text("Mixpult")
        case .wireless: L10n.text("Bezdrátové mikrofony")
        case .alerts: L10n.text("Upozornění a alarmy")
        case .recording: L10n.text("Záznam a historie")
        }
    }

    var systemImage: String {
        switch self {
        case .input: "mic"
        case .display: "rectangle.split.3x1"
        case .analysis: "waveform"
        case .mixer: "slider.vertical.3"
        case .wireless: "antenna.radiowaves.left.and.right"
        case .alerts: "bell"
        case .recording: "record.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: MeterModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("SettingsView.selectedSection") private var selection: SettingsSection = .input
    @State private var draggedMetric: Metric?
    @State private var isAnalysisNotesPresented = false
    /// Bumped when a console is chosen from the list, which must win over an
    /// address still being typed.
    @State private var mixerAddressDiscardRevision = 0

    private static let instantMetrics: [Metric] = [.aSlow, .cSlow, .lafMax, .lcPeak]
    private static let oneSecondMetrics: [Metric] = [
        .laeq1Second, .lceq1Second, .lzeq1Second,
        .lafMax1Second, .lasMax1Second, .lcPeak1Second
    ]
    private static let longTermMetrics: [Metric] = [
        .laeq1, .laeq10, .laeq15, .laeq30, .lceq1, .lceq10, .lceq30
    ]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(selection.title)
                        .font(.title2.bold())
                    Spacer()
                    Button(L10n.text("Hotovo")) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                Divider()
                sectionContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 1240, height: 440)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text("Nastavení SPL"))
                .font(.headline)
                .padding(.horizontal, 10)
                .padding(.top, 18)
                .padding(.bottom, 10)

            ForEach(SettingsSection.allCases) { section in
                sidebarRow(section)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .background(Color.secondary.opacity(0.06))
    }

    private func sidebarRow(_ section: SettingsSection) -> some View {
        Button {
            selection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.systemImage)
                    .frame(width: 20)
                Text(section.title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge = badgeColor(for: section) {
                    Circle()
                        .fill(badge)
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selection == section ? Color.accentColor.opacity(0.25) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == section ? .isSelected : [])
    }

    private func badgeColor(for section: SettingsSection) -> Color? {
        switch section {
        case .input:
            return !model.isRunning || model.selectedCalibration == nil ? .orange : nil
        case .recording:
            return model.isRecording ? .red : nil
        case .display, .analysis, .mixer, .wireless, .alerts:
            return nil
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selection {
        case .input: scrolling { inputSection }
        case .display: scrolling { displaySection }
        case .analysis: scrolling { analysisSection }
        case .mixer: scrolling { mixerSection }
        case .wireless: scrolling { wirelessSection }
        case .alerts: scrolling { alertsSection }
        case .recording: recordingSection
        }
    }

    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let content = content()
        return ScrollView {
            content
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Input and calibration

    private var inputSection: some View {
        HStack(alignment: .top, spacing: 16) {
            settingsGroup(L10n.text("Zvukový vstup")) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    settingRow(L10n.text("Zařízení")) {
                        HStack {
                            Picker(L10n.text("Zařízení"), selection: deviceBinding) {
                                Text(L10n.text("Nevybráno")).tag("")
                                ForEach(model.devices) { device in
                                    Text(device.name).tag(device.uid)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 300)
                            Button(L10n.text("Obnovit")) { model.refreshDevices() }
                        }
                    }
                    if let device = model.selectedDevice {
                        settingRow(L10n.text("Kanál")) {
                            Picker(L10n.text("Kanál"), selection: channelBinding) {
                                ForEach(0..<device.inputChannelCount, id: \.self) { channel in
                                    Text(L10n.format("Kanál %d", Int32(channel + 1))).tag(channel)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(model.isRunning ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(model.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(L10n.text("Spustit vstup")) { model.startSelectedInput() }
                    .disabled(model.settings.input == nil || model.isRunning)
            }

            settingsGroup(L10n.text("Kalibrace")) {
                if let calibration = model.selectedCalibration {
                    Label {
                        Text(L10n.format(
                            "Kalibrováno %@",
                            calibration.calibratedAt.formatted(date: .abbreviated, time: .shortened)
                        ))
                    } icon: {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                } else {
                    Label {
                        Text(L10n.text("Nekalibrováno"))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                HStack(spacing: 12) {
                    Button(L10n.text("Kalibrovat na 94 dB")) { model.beginCalibration() }
                        .disabled(!model.isRunning)
                    if let progress = model.calibrationProgress {
                        ProgressView(value: progress)
                            .frame(width: 200)
                    }
                }

                caption(L10n.text("Spusťte vstup, přiložte kalibrátor 1 kHz / 94 dB a zvolte Kalibrovat. Kalibrace trvá nejméně 9 s."))
            }
        }
    }

    // MARK: - Displayed measurements

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGroup(L10n.text("Pořadí zobrazených měření")) {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(model.settings.displayedMetrics) { metric in
                            metricOrderChip(metric)
                                .onDrop(
                                    of: [UTType.plainText.identifier],
                                    delegate: MetricDropDelegate(
                                        targetMetric: metric,
                                        draggedMetric: $draggedMetric,
                                        move: model.moveMetric
                                    )
                                )
                        }
                        clockChip
                    }
                    .padding(.vertical, 4)
                }

                HStack {
                    caption(L10n.text("Sloupce na displeji zleva doprava. Přetažením nebo šipkami změňte pořadí."))
                    Spacer()
                    caption(L10n.format(
                        "Sloupce na displeji: %d + hodiny",
                        Int32(model.settings.displayedMetrics.count)
                    ))
                }
            }

            settingsGroup(L10n.text("Zobrazená měření")) {
                HStack(alignment: .top, spacing: 24) {
                    metricToggleColumn(L10n.text("Okamžité hodnoty"), metrics: Self.instantMetrics)
                    metricToggleColumn(L10n.text("Hodnoty za 1 s"), metrics: Self.oneSecondMetrics)
                    metricToggleColumn(L10n.text("Dlouhodobé Leq"), metrics: longTermAndOtherMetrics)
                }
            }
        }
    }

    /// Long-term metrics plus any metric not assigned to a group, so a newly
    /// added metric is never missing from the settings.
    private var longTermAndOtherMetrics: [Metric] {
        let grouped = Set(Self.instantMetrics + Self.oneSecondMetrics + Self.longTermMetrics)
        return Self.longTermMetrics + Metric.allCases.filter { !grouped.contains($0) }
    }

    private func metricToggleColumn(_ title: String, metrics: [Metric]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(metrics) { metric in
                Toggle(metric.title, isOn: metricBinding(metric))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metricOrderChip(_ metric: Metric) -> some View {
        let index = model.settings.displayedMetrics.firstIndex(of: metric) ?? 0
        let lastIndex = model.settings.displayedMetrics.count - 1

        return VStack(spacing: 6) {
            Text(metric.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            HStack(spacing: 6) {
                Button {
                    model.moveMetric(metric, by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .help(L10n.text("Posunout vlevo"))
                .accessibilityLabel(L10n.format("Posunout %@ vlevo", metric.title))

                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Button {
                    model.moveMetric(metric, by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(index == lastIndex)
                .help(L10n.text("Posunout vpravo"))
                .accessibilityLabel(L10n.format("Posunout %@ vpravo", metric.title))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 108)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.3))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .help(L10n.text("Přetažením změňte pořadí"))
        .onDrag {
            draggedMetric = metric
            return NSItemProvider(object: metric.rawValue as NSString)
        }
    }

    private var clockChip: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock")
            Text(L10n.text("Hodiny"))
                .font(.callout)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 84)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }

    // MARK: - Analysis

    private var analysisSection: some View {
        HStack(alignment: .top, spacing: 16) {
            settingsGroup(L10n.text("Zobrazení analýzy")) {
                Picker(L10n.text("Zobrazení analýzy"), selection: analysisDisplayModeBinding) {
                    ForEach(model.availableAnalysisDisplayModes) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    settingRow(L10n.text("Referenční kanál")) {
                        Picker(L10n.text("Referenční kanál"), selection: referenceChannelBinding) {
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
                        .labelsHidden()
                        .fixedSize()
                        .disabled(
                            (model.selectedDevice?.inputChannelCount ?? 0) < 2
                                || !model.canReconfigureAnalysisInput
                        )
                    }

                    settingRow(L10n.text("Frekvenční rozsah")) {
                        Picker(
                            L10n.text("Frekvenční rozsah"),
                            selection: $model.settings.spectrogram.frequencyRange
                        ) {
                            ForEach(SpectrogramFrequencyRange.allCases) { range in
                                Text(range.title).tag(range)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }

                    if model.settings.spectrogram.displayMode.showsTransferFunction {
                        settingRow(L10n.text("Svislý rozsah TF")) {
                            numericInput(
                                prefix: "±",
                                value: transferFunctionRangeBinding,
                                unit: "dB",
                                validation: SpectrogramSettings.validatedTransferFunctionRange
                            )
                        }

                        settingRow(L10n.text("Vyhlazení")) {
                            Picker(
                                L10n.text("Vyhlazení"),
                                selection: $model.settings.spectrogram.transferFunctionSmoothing
                            ) {
                                ForEach(TransferFunctionSmoothing.allCases) { smoothing in
                                    Text(smoothing.title).tag(smoothing)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }

                        settingRow(L10n.text("Časové okno")) {
                            Picker(
                                L10n.text("Časové okno"),
                                selection: $model.settings.spectrogram.transferFunctionWindow
                            ) {
                                ForEach(TransferFunctionWindowType.allCases) { windowType in
                                    Text(windowType.title).tag(windowType)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }

                if model.settings.spectrogram.displayMode.showsTransferFunction {
                    caption(L10n.text("Křivka používá průběžné zarovnání impulsní odezvy a frekvenčně závislé časové okno."))
                    if model.settings.spectrogram.transferFunctionWindow == .tracking {
                        caption(L10n.text("Sledující okno se v každém pásmu posouvá za energetickým maximem, takže zachová i zpožděnou energii výhybky, basreflexu nebo subwooferu."))
                    }
                }
            }

            settingsGroup(L10n.text("Spektrogram")) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    settingRow(L10n.text("Historie")) {
                        Picker(
                            L10n.text("Historie"),
                            selection: $model.settings.spectrogram.historyDuration
                        ) {
                            ForEach(SpectrogramHistoryDuration.allCases) { duration in
                                Text(duration.title).tag(duration)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }

                    settingRow(L10n.text("Intenzita")) {
                        Picker(
                            L10n.text("Intenzita"),
                            selection: $model.settings.spectrogram.intensity
                        ) {
                            ForEach(SpectrogramIntensity.allCases) { intensity in
                                Text(intensity.title).tag(intensity)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }

                    settingRow(L10n.text("Barevná stupnice")) {
                        Picker(
                            L10n.text("Barevná stupnice"),
                            selection: $model.settings.spectrogram.palette
                        ) {
                            ForEach(SpectrogramPalette.allCases) { palette in
                                Text(palette.title).tag(palette)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }

                    settingRow(L10n.text("Horní hranice")) {
                        numericInput(
                            value: spectrogramUpperLevelBinding,
                            unit: "dB SPL",
                            validation: SpectrogramSettings.validatedUpperLevel
                        )
                    }

                    settingRow(L10n.text("Dynamický rozsah")) {
                        numericInput(
                            value: spectrogramDynamicRangeBinding,
                            unit: "dB",
                            validation: SpectrogramSettings.validatedDynamicRange
                        )
                    }
                }

                if model.selectedCalibration == nil {
                    caption(L10n.text("Bez kalibrace končí stupnice na 0 dBFS; nastavená horní hranice SPL se použije po kalibraci."))
                }

                Button {
                    isAnalysisNotesPresented.toggle()
                } label: {
                    Label(L10n.text("Technické poznámky"), systemImage: "info.circle")
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $isAnalysisNotesPresented, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        noteText(L10n.text("Po kalibraci barvy zobrazují přibližnou nekorigovanou hladinu (Z); bez kalibrace používají relativní stupnici dBFS."))
                        noteText(L10n.text("Nízké frekvence používají jednotlivé FFT biny normalizované na šířku 1/24 oktávy; vyšší frekvence používají integrovaná 1/24oktávová pásma."))
                        noteText(L10n.text("Skutečný horní limit závisí na vzorkovací frekvenci vstupu."))
                    }
                    .padding(16)
                    .frame(width: 380)
                }
            }
        }
    }

    // MARK: - Mixing console

    private var mixerSection: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                mixerConnectionGroup
                settingsGroup(L10n.text("Mixpulty na síti")) {
                    MixerConsoleList(
                        scanner: model.mixerScanner,
                        settings: model.settings.mixer,
                        select: { console in
                            model.selectMixerConsole(console)
                            mixerAddressDiscardRevision += 1
                        },
                        selectAutomatic: {
                            model.clearMixerConsoleSelection()
                            mixerAddressDiscardRevision += 1
                        }
                    )
                    caption(L10n.text("Vyberte mixpult, ke kterému se má aplikace připojovat. WING se pozná podle sériového čísla, X32 a M32 podle názvu v síti a modelu. Dokud je mixpult vybraný, aplikace se k žádnému jinému nepřipojí."))
                }
            }

            if model.settings.mixer.kind != .none {
                settingsGroup(L10n.text("Sekce meter bridge")) {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), alignment: .leading),
                            count: 3
                        ),
                        alignment: .leading,
                        spacing: 6
                    ) {
                        ForEach(model.settings.mixer.kind.sections) { section in
                            Toggle(section.title, isOn: mixerSectionBinding(section))
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        // The network is scanned only while this page is shown.
        .onAppear { model.mixerScanner.start() }
        .onDisappear { model.mixerScanner.stop() }
    }

    private var mixerConnectionGroup: some View {
        settingsGroup(L10n.text("Připojení mixpultu")) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                settingRow(L10n.text("Typ")) {
                    Picker(L10n.text("Typ"), selection: mixerKindBinding) {
                        ForEach(MixerKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if model.settings.mixer.kind != .none {
                    settingRow(L10n.text("Adresa")) {
                        MixerAddressField(
                            address: model.settings.mixer.address,
                            commit: model.setMixerAddress,
                            discardRevision: mixerAddressDiscardRevision
                        )
                        .frame(maxWidth: 220)
                    }
                }
            }

            MixerStatusLine(bridge: model.mixerBridge)

            if model.settings.mixer.kind != .none {
                caption(L10n.text("Prázdná adresa znamená automatické vyhledání v síti. Pokud se mixpult nenajde, zadejte jeho IP adresu a v Nastavení systému povolte přístup k místní síti."))
                if model.settings.mixer.connectionAddress != nil {
                    caption(L10n.text("Zadaná adresa má přednost před výběrem ze seznamu mixpultů na síti."))
                }
            }
        }
    }

    // MARK: - Wireless microphones

    private var wirelessSection: some View {
        HStack(alignment: .top, spacing: 16) {
            settingsGroup(L10n.text("Přijímače Shure")) {
                Toggle(L10n.text("Sledovat bezdrátové mikrofony"), isOn: wirelessEnabledBinding)

                if model.settings.wireless.isEnabled {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        settingRow(L10n.text("Adresy")) {
                            MixerAddressField(
                                address: model.settings.wireless.addresses,
                                commit: model.setWirelessAddresses
                            )
                            .frame(maxWidth: 300)
                        }
                    }
                    WirelessScanButton(
                        monitor: model.wirelessMonitor,
                        scan: model.wirelessMonitor.scanNetwork
                    )
                    caption(L10n.text("Přijímače ULX-D, SLX-D a QLX-D se hledají automaticky podle toho, co samy oznamují v síti. Pokud se některý nenajde, zadejte jeho IP adresu (více adres oddělte čárkou) nebo prohledejte síť: aplikace se pak zeptá všech adres ve vaší podsíti /24 na portu 2202. Z přijímačů se jen čte a nic se v nich nemění."))
                }
            }

            if model.settings.wireless.isEnabled {
                settingsGroup(L10n.text("Nalezené přijímače")) {
                    WirelessReceiverList(monitor: model.wirelessMonitor)
                }
            }
        }
    }

    // MARK: - Alerts and alarms

    private var alertsSection: some View {
        HStack(alignment: .top, spacing: 16) {
            settingsGroup(L10n.text("Barevné upozornění")) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    settingRow(L10n.text("A: přechod / žlutá")) {
                        thresholdInputs(
                            start: $model.settings.thresholds.aTransitionStart,
                            yellow: $model.settings.thresholds.aYellow
                        )
                    }
                    settingRow(L10n.text("C: přechod / žlutá")) {
                        thresholdInputs(
                            start: $model.settings.thresholds.cTransitionStart,
                            yellow: $model.settings.thresholds.cYellow
                        )
                    }
                }
                caption(L10n.text("Barvy jsou pouze orientační vizuální upozornění pro live sound."))
            }

            settingsGroup(L10n.text("Alarmy měření")) {
                Toggle(L10n.text("Zaznamenávat překročení limitů"), isOn: $model.alarmSettings.isEnabled)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    settingRow("LAeq 30 min") {
                        numericInput(value: $model.alarmSettings.laeq30MinuteLimit, unit: "dB")
                    }
                    settingRow("LCpeak") {
                        numericInput(value: $model.alarmSettings.lcPeakLimit, unit: "dB")
                    }
                }
                .disabled(!model.alarmSettings.isEnabled)
                caption(L10n.text("Výchozí hodnoty jsou orientační. Neprokazují shodu měření s DIN 15905-5."))
            }
        }
    }

    private func thresholdInputs(start: Binding<Double>, yellow: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            NumericTextField(value: start)
                .frame(width: 60)
            Text("dB →")
                .foregroundStyle(.secondary)
            NumericTextField(value: yellow)
                .frame(width: 60)
            Text("dB")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Recording and history

    private var recordingSection: some View {
        HStack(alignment: .top, spacing: 16) {
            ScrollView {
                settingsGroup(L10n.text("Měřicí relace")) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        settingRow(L10n.text("Název akce")) {
                            TextField(L10n.text("Název akce"), text: $model.recordingMetadata.eventName)
                                .labelsHidden()
                        }
                        settingRow(L10n.text("Místo měření")) {
                            TextField(L10n.text("Místo měření"), text: $model.recordingMetadata.location)
                                .labelsHidden()
                        }
                        settingRow(L10n.text("Identifikace mikrofonu")) {
                            TextField(L10n.text("Identifikace mikrofonu"), text: $model.recordingMetadata.microphoneID)
                                .labelsHidden()
                        }
                        settingRow(L10n.text("Poznámka")) {
                            TextField(L10n.text("Poznámka"), text: $model.recordingMetadata.note, axis: .vertical)
                                .labelsHidden()
                                .lineLimit(2...4)
                        }
                    }
                    .disabled(model.isRecording || model.isPreparingRecording)

                    caption(
                        model.isRecording || model.isPreparingRecording
                            ? L10n.text("Během záznamu nelze metadata měnit.")
                            : L10n.text("Metadata se uloží do následující měřicí relace.")
                    )
                }
                .padding(.vertical, 20)
                .padding(.leading, 20)
            }
            .frame(width: 480)

            settingsGroup(L10n.text("Historie záznamů")) {
                if model.recordingHistory.isEmpty {
                    Text(L10n.text("Zatím nebyl vytvořen žádný záznam."))
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.recordingHistory) { entry in
                                historyRow(entry)
                                if entry.id != model.recordingHistory.last?.id { Divider() }
                            }
                        }
                        .padding(.trailing, 8)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .padding(.vertical, 20)
            .padding(.trailing, 20)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func historyRow(_ entry: RecordingHistoryEntry) -> some View {
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
    }

    // MARK: - Building blocks

    private func settingsGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let content = content()
        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func settingRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let content = content()
        return GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func numericInput(
        prefix: String? = nil,
        value: Binding<Double>,
        unit: String,
        validation: @escaping (Double) -> Double = { $0 }
    ) -> some View {
        HStack(spacing: 6) {
            if let prefix { Text(prefix) }
            NumericTextField(value: value, validation: validation)
                .frame(width: 60)
            Text(unit)
                .foregroundStyle(.secondary)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func noteText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Bindings

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

    private var mixerKindBinding: Binding<MixerKind> {
        Binding(
            get: { model.settings.mixer.kind },
            set: model.setMixerKind
        )
    }

    private func mixerSectionBinding(_ section: MixerMeterSectionDescriptor) -> Binding<Bool> {
        Binding(
            get: { model.settings.mixer.isVisible(section) },
            set: { model.setMixerSection(section, isVisible: $0) }
        )
    }

    private var wirelessEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.settings.wireless.isEnabled },
            set: model.setWirelessEnabled
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

/// Commits when editing ends, so typing does not restart the connection.
private struct MixerAddressField: View {
    let address: String
    let commit: (String) -> Void
    /// A change drops an uncommitted draft for the stored address, so it is
    /// not committed later, for example when focus leaves the field.
    var discardRevision = 0

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $draft, prompt: Text(L10n.text("Automaticky")))
            .labelsHidden()
            .focused($isFocused)
            .onAppear { draft = address }
            .onSubmit { commit(draft) }
            .onChange(of: isFocused) { focused in
                if !focused { commit(draft) }
            }
            .onChange(of: address) { newValue in
                if !isFocused { draft = newValue }
            }
            .onChange(of: discardRevision) { _ in
                draft = address
            }
            .onDisappear { commit(draft) }
    }
}

private struct MixerStatusLine: View {
    @ObservedObject var bridge: MixerBridgeModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusColor: Color {
        switch bridge.phase {
        case .connected:
            return .green
        case .invalidAddress:
            return .orange
        case .disabled, .noSectionsSelected, .connecting, .waitingToRetry:
            return .secondary
        }
    }

    private var statusText: String {
        switch bridge.phase {
        case .disabled:
            return L10n.text("Mixpult není nastaven.")
        case .noSectionsSelected:
            return MixerBridgeNotice.noSections
        case .invalidAddress:
            return MixerBridgeNotice.invalidAddress
        case .connecting:
            if let target = bridge.target {
                return MixerBridgeNotice.searching(for: target)
            }
            return L10n.text("Hledám mixpult…")
        case .waitingToRetry:
            if let target = bridge.target {
                return MixerBridgeNotice.unavailable(target)
            }
            return L10n.text("Mixpult není dostupný. Připojení se opakuje automaticky.")
        case .connected(let identity):
            let description = identity.name.isEmpty
                ? identity.address
                : "\(identity.name) (\(identity.address))"
            return L10n.format("Připojeno: %@", description)
        }
    }
}

/// Every console found on the network, of every supported type, to choose the
/// one the application connects to.
private struct MixerConsoleList: View {
    @ObservedObject var scanner: MixerScanner
    let settings: MixerSettings
    let select: (DiscoveredMixer) -> Void
    let selectAutomatic: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if settings.kind != .none {
                row(isSelected: usesList && settings.preferredConsole == nil, action: selectAutomatic) {
                    Text(L10n.text("Automaticky – první nalezený"))
                        .lineLimit(1)
                }
            }
            if let preferred = settings.preferredConsole,
               !scanner.consoles.contains(where: { preferred.matches($0) }) {
                // Not a button: there is nothing to connect to until it is found.
                rowContent(isSelected: usesList) {
                    label(
                        kind: preferred.kind,
                        name: preferred.name,
                        model: preferred.model,
                        address: preferred.address,
                        serial: preferred.serial
                    )
                    Text(L10n.text("Nenalezen v síti"))
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            ForEach(scanner.consoles) { console in
                row(
                    isSelected: usesList && settings.preferredConsole?.matches(console) == true,
                    action: { select(console) }
                ) {
                    label(
                        kind: console.kind,
                        name: console.name,
                        model: console.model,
                        address: console.address,
                        serial: console.serial
                    )
                }
            }
            if scanner.consoles.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.text("Hledám mixpulty…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
    }

    /// An entered address takes precedence over the list, so nothing in it is
    /// marked as in use.
    private var usesList: Bool { settings.connectionAddress == nil }

    private func row<Content: View>(
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let rowView = rowContent(isSelected: isSelected, content: content)
        return Button(action: action) {
            rowView
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func rowContent<Content: View>(
        isSelected: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            content()
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    /// The name, or what identifies a console without one, then the rest.
    private func label(
        kind: MixerKind,
        name: String,
        model: String,
        address: String,
        serial: String
    ) -> some View {
        let candidates = [name, model, address].map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let title = candidates.first(where: { !$0.isEmpty }) ?? kind.title
        var parts = [kind.title] + candidates.dropFirst().filter { !$0.isEmpty && $0 != title }
        let trimmedSerial = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSerial.isEmpty { parts.append("S/N \(trimmedSerial)") }
        let detail = parts.filter { $0 != title }.joined(separator: " · ")
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: title)
                .lineLimit(1)
            Text(verbatim: detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct WirelessScanButton: View {
    @ObservedObject var monitor: WirelessMonitorModel
    let scan: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(L10n.text("Prohledat síť"), action: scan)
                .disabled(monitor.isScanning)
            if monitor.isScanning {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.text("Prohledávám síť…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct WirelessReceiverList: View {
    @ObservedObject var monitor: WirelessMonitorModel

    var body: some View {
        if monitor.receivers.isEmpty {
            Text(L10n.text("Zatím nebyl nalezen žádný přijímač."))
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(monitor.receivers) { receiver in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(receiver.phase == .connected ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(verbatim: title(of: receiver))
                            .lineLimit(1)
                        Text(statusText(of: receiver))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func title(of receiver: WirelessReceiverStatus) -> String {
        let description = [receiver.model, receiver.name]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return description.isEmpty ? receiver.address : "\(description) (\(receiver.address))"
    }

    private func statusText(of receiver: WirelessReceiverStatus) -> String {
        switch receiver.phase {
        case .connecting: L10n.text("Připojuji…")
        case .connected: L10n.text("Připojeno")
        case .unsupported: L10n.text("Tento model není podporován.")
        case .unavailable: L10n.text("Nedostupný. Připojení se opakuje automaticky.")
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
            .multilineTextAlignment(.trailing)
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
