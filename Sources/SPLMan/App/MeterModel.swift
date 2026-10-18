import AppKit
import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class MeterModel: ObservableObject {
    @Published private(set) var snapshot = MeterSnapshot.empty
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var status = L10n.text("Vyberte vstup a proveďte kalibraci.")
    @Published private(set) var isRunning = false
    @Published private(set) var calibrationProgress: Double?
    @Published private(set) var now = Date()
    @Published private(set) var isRecording = false
    @Published private(set) var isPreparingRecording = false
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var recordingError: String?
    @Published private(set) var recordingHistory: [RecordingHistoryEntry]
    @Published private(set) var audioDropoutCount = 0
    @Published private(set) var isClippingDetected = false
    @Published private(set) var exceededLimits: Set<Metric> = []
    @Published private(set) var selectedEventSessionID: UUID?
    @Published private(set) var selectedRecordingEvents: [RecordingEventHistoryEntry] = []
    @Published private(set) var isEventHistoryLoading = false
    @Published private(set) var isEventHistoryTruncated = false
    @Published private(set) var eventHistoryError: String?
    @Published var recordingMetadata: RecordingMetadataDraft {
        didSet { historyStore.saveMetadata(recordingMetadata) }
    }
    @Published var alarmSettings: AlarmSettings {
        didSet {
            historyStore.saveAlarmSettings(alarmSettings)
            secondRecorder?.updateConfiguration(
                alarmSettings: alarmSettings,
                displayedMetrics: settings.displayedMetrics
            )
        }
    }
    @Published var isSettingsPresented = false
    @Published var settings: PersistedSettings {
        didSet {
            store.save(settings)
            guard oldValue.displayedMetrics != settings.displayedMetrics else { return }
            secondRecorder?.updateConfiguration(
                alarmSettings: alarmSettings,
                displayedMetrics: settings.displayedMetrics
            )
        }
    }

    private let store: SettingsStore
    private let recordingErrorStore: RecordingErrorStore
    private let historyStore: RecordingHistoryStore
    private let engine = AudioCaptureEngine()
    private var timer: Timer?
    private var calibrationSession: CalibrationSession?
    private var lastDeviceScan = Date.distantPast
    private var calibrationStartedAt: Date?
    private var audioStartedAt: Date?
    private var lastAudioSnapshotAt: Date?
    private var logger: CSVMeasurementLogger?
    private var pendingLogger: CSVMeasurementLogger?
    private var pendingRecordingID: UUID?
    private var savePanelRequestID: UUID?
    private var closingLoggers: [CSVMeasurementLogger] = []
    private var secondRecorder: CompletedSecondRecorder?
    private var activeSessionID: UUID?
    private var eventHistoryRequestID: UUID?

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        recordingErrorStore = RecordingErrorStore()
        historyStore = RecordingHistoryStore()
        settings = store.load()
        recordingError = recordingErrorStore.load()
        recordingMetadata = historyStore.loadMetadata()
        alarmSettings = historyStore.loadAlarmSettings()
        recordingHistory = historyStore.loadHistory()
        refreshDevices()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.consumeAudioSnapshot() }
        }
        requestPermissionAndRestoreInput()
    }

    deinit { timer?.invalidate() }

    var selectedDevice: AudioInputDevice? {
        guard let uid = settings.input?.deviceUID else { return nil }
        return devices.first { $0.uid == uid }
    }

    var selectedCalibration: CalibrationRecord? {
        guard let input = settings.input else { return nil }
        return settings.calibrations[CalibrationKey(deviceUID: input.deviceUID, channel: input.channel)]
    }

    var canStartRecording: Bool {
        isRunning && selectedCalibration != nil && calibrationSession == nil
    }

    var operationalStatus: MeterOperationalStatus {
        if recordingError != nil { return .storageError }
        if !isRunning { return .warning(L10n.text("MĚŘENÍ ZASTAVENO")) }
        var critical: [String] = []
        if audioDropoutCount > 0 {
            critical.append(L10n.format(
                "VÝPADKY OD SPUŠTĚNÍ ×%d",
                Int32(clamping: audioDropoutCount)
            ))
        }
        if isClippingDetected { critical.append("CLIP") }
        if !critical.isEmpty { return .warning(critical.joined(separator: " · ")) }
        var notices: [String] = []
        if !exceededLimits.isEmpty { notices.append(L10n.text("PŘEKROČEN LIMIT")) }
        if selectedCalibration == nil { notices.append(L10n.text("KALIBRACE NEPLATNÁ")) }
        if !notices.isEmpty { return .notice(notices.joined(separator: " · ")) }
        return .ready
    }

    func refreshDevices() {
        devices = AudioDeviceRepository.inputDevices()
        if let uid = settings.input?.deviceUID,
           !devices.contains(where: { $0.uid == uid }) {
            stop(status: L10n.text("Uložené zařízení není připojeno. Měření je zastaveno."))
        }
    }

    func selectDevice(uid: String) {
        guard let device = devices.first(where: { $0.uid == uid }) else { return }
        secondRecorder?.recordEvent(.audioDeviceChanged, metadata: [
            "previous_device_uid": settings.input?.deviceUID ?? "",
            "new_device_uid": device.uid
        ])
        stopRecording()
        settings.input = InputSelection(deviceUID: device.uid, channel: 0)
        snapshot = .empty
        startSelectedInput()
    }

    func selectChannel(_ channel: Int) {
        guard var input = settings.input,
              let device = selectedDevice,
              channel >= 0, channel < device.inputChannelCount else { return }
        secondRecorder?.recordEvent(.configurationChanged, metadata: [
            "setting": "input_channel",
            "previous_value": String(input.channel + 1),
            "new_value": String(channel + 1)
        ])
        stopRecording()
        input.channel = channel
        settings.input = input
        snapshot = .empty
        startSelectedInput()
    }

    func toggleMetric(_ metric: Metric) {
        if let index = settings.displayedMetrics.firstIndex(of: metric) {
            guard settings.displayedMetrics.count > 1 else { return }
            settings.displayedMetrics.remove(at: index)
        } else {
            settings.displayedMetrics.append(metric)
        }
    }

    func moveMetric(_ metric: Metric, to target: Metric) {
        guard let sourceIndex = settings.displayedMetrics.firstIndex(of: metric),
              let targetIndex = settings.displayedMetrics.firstIndex(of: target),
              sourceIndex != targetIndex else { return }
        settings.displayedMetrics.remove(at: sourceIndex)
        settings.displayedMetrics.insert(metric, at: targetIndex)
    }

    func moveMetric(_ metric: Metric, by offset: Int) {
        guard let sourceIndex = settings.displayedMetrics.firstIndex(of: metric) else { return }
        let targetIndex = sourceIndex + offset
        guard settings.displayedMetrics.indices.contains(targetIndex) else { return }
        settings.displayedMetrics.swapAt(sourceIndex, targetIndex)
    }

    func beginCalibration() {
        guard isRunning, let input = settings.input else {
            status = L10n.text("Nejdříve spusťte vybraný vstup.")
            return
        }
        stopRecording()
        do {
            // Start with empty Slow and Leq state. The engine is restarted
            // again after calibration so the 94 dB tone never contaminates Leq.
            try engine.start(selection: input)
        } catch {
            stop(status: error.localizedDescription)
            return
        }
        snapshot = .empty
        calibrationSession = CalibrationSession()
        calibrationStartedAt = Date()
        audioStartedAt = Date()
        lastAudioSnapshotAt = nil
        calibrationProgress = 0
        status = L10n.text("Kalibrace: držte stabilní tón 94 dB / 1 kHz…")
    }

    func startSelectedInput() {
        stopRecording()
        calibrationSession = nil
        calibrationProgress = nil
        snapshot = .empty
        audioDropoutCount = 0
        isClippingDetected = false
        exceededLimits = []
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            stop(status: L10n.text("Aplikace nemá oprávnění k mikrofonu."))
            return
        }
        guard let input = settings.input else {
            stop(status: L10n.text("Vyberte zvukové zařízení a kanál."))
            return
        }
        do {
            try engine.start(selection: input)
            isRunning = true
            audioStartedAt = Date()
            lastAudioSnapshotAt = nil
            status = selectedCalibration == nil
                ? L10n.text("Vstup běží. Proveďte kalibraci 94 dB.")
                : L10n.text("Měření běží.")
        } catch {
            stop(status: error.localizedDescription)
        }
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            chooseRecordingDestination()
        }
    }

    func dismissRecordingError() {
        recordingError = nil
        recordingErrorStore.clear()
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        stopRecording(waitUntilClosed: true, finalStatus: .interrupted)
        for closingLogger in closingLoggers {
            closingLogger.stop(waitUntilClosed: true)
        }
        closingLoggers.removeAll()
        engine.stop()
    }

    private func requestPermissionAndRestoreInput() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            if settings.input != nil { startSelectedInput() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted, self.settings.input != nil {
                        self.startSelectedInput()
                    } else if !granted {
                        self.status = L10n.text("Přístup k mikrofonu byl zamítnut.")
                    }
                }
            }
        default:
            status = L10n.text("Přístup k mikrofonu je vypnutý v Nastavení systému.")
        }
    }

    private func stop(status: String) {
        stopRecording(finalStatus: .interrupted)
        engine.stop()
        calibrationSession = nil
        calibrationStartedAt = nil
        calibrationProgress = nil
        audioStartedAt = nil
        lastAudioSnapshotAt = nil
        isRunning = false
        snapshot = .empty
        self.status = status
    }

    private func consumeAudioSnapshot() {
        now = Date()
        if secondRecorder == nil, !isPreparingRecording {
            while engine.takeCompletedSecond() != nil {}
            consumeAudioHealthForDisplay()
        }
        if now.timeIntervalSince(lastDeviceScan) >= 1,
           let uid = settings.input?.deviceUID {
            lastDeviceScan = now
            let currentDevices = AudioDeviceRepository.inputDevices()
            if !currentDevices.contains(where: { $0.uid == uid }) {
                devices = currentDevices
                stop(status: L10n.text("Vybrané zařízení bylo odpojeno. Měření je zastaveno."))
                return
            }
        }
        guard let raw = engine.latest.take() else {
            checkAudioTimeouts()
            return
        }
        lastAudioSnapshotAt = now
        if var calibrationSession,
           let rawASlow = raw.aSlow,
           let rawCSlow = raw.cSlow,
           let toneConcentration = raw.oneKilohertzConcentration {
            switch calibrationSession.add(
                rawASlowDB: rawASlow,
                rawCSlowDB: rawCSlow,
                toneConcentration: toneConcentration
            ) {
            case let .collecting(progress):
                self.calibrationSession = calibrationSession
                calibrationProgress = progress
            case let .calibrated(offset):
                guard let input = settings.input else { return }
                settings.calibrations[CalibrationKey(
                    deviceUID: input.deviceUID,
                    channel: input.channel
                )] = CalibrationRecord(offsetDB: offset, calibratedAt: Date())
                finishCalibration(status: L10n.text("Kalibrace dokončena."))
            case let .unstable(spread):
                finishCalibration(status: L10n.format(
                    "Kalibrace selhala: signál kolísal o %.1f dB.", spread
                ))
            case let .invalidSignal(concentration, cMinusA):
                finishCalibration(status: L10n.format(
                    "Kalibrace selhala: ověřte kalibrátor 1 kHz (tón %.0f %%, C−A %+.1f dB).",
                    concentration * 100, cMinusA
                ))
            }
        }
        if self.calibrationSession != nil,
           let calibrationStartedAt,
           now.timeIntervalSince(calibrationStartedAt) > 12 {
            finishCalibration(
                status: L10n.text("Kalibrace selhala: na vybraném kanálu není platný signál 94 dB / 1 kHz.")
            )
            return
        }
        guard isRunning else { return }

        guard let offset = selectedCalibration?.offsetDB else {
            snapshot = .empty
            return
        }
        var values: [Metric: Double] = [:]
        if let value = raw.aSlow { values[.aSlow] = value + offset }
        if let value = raw.cSlow { values[.cSlow] = value + offset }
        if let value = raw.laeq1 { values[.laeq1] = value + offset }
        if let value = raw.laeq10 { values[.laeq10] = value + offset }
        if let value = raw.laeq30 { values[.laeq30] = value + offset }
        if let value = raw.lceq1 { values[.lceq1] = value + offset }
        if let value = raw.lceq10 { values[.lceq10] = value + offset }
        if let value = raw.lceq30 { values[.lceq30] = value + offset }
        if let value = raw.laeq15 { values[.laeq15] = value + offset }
        if let value = raw.laeq1Second { values[.laeq1Second] = value + offset }
        if let value = raw.lceq1Second { values[.lceq1Second] = value + offset }
        if let value = raw.lzeq1Second { values[.lzeq1Second] = value + offset }
        if let value = raw.lafMax1Second { values[.lafMax1Second] = value + offset }
        if let value = raw.lasMax1Second { values[.lasMax1Second] = value + offset }
        if let value = raw.lcPeak1Second { values[.lcPeak1Second] = value + offset }
        if let value = raw.lcPeak { values[.lcPeak] = value + offset }
        if let value = raw.lafMax { values[.lafMax] = value + offset }
        snapshot = MeterSnapshot(values: values)
    }

    func revealRecording(_ entry: RecordingHistoryEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.filePath)])
    }

    func toggleRecordingEvents(_ entry: RecordingHistoryEntry) {
        if selectedEventSessionID == entry.id {
            eventHistoryRequestID = nil
            selectedEventSessionID = nil
            selectedRecordingEvents = []
            isEventHistoryLoading = false
            isEventHistoryTruncated = false
            eventHistoryError = nil
            return
        }

        let requestID = UUID()
        eventHistoryRequestID = requestID
        selectedEventSessionID = entry.id
        selectedRecordingEvents = []
        isEventHistoryLoading = true
        isEventHistoryTruncated = false
        eventHistoryError = nil
        let url = URL(fileURLWithPath: entry.filePath)
        let sessionID = entry.id

        if activeSessionID == entry.id, let logger {
            logger.flush { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.eventHistoryRequestID == requestID else { return }
                    switch result {
                    case .success:
                        self.loadRecordingEvents(at: url, sessionID: sessionID, requestID: requestID)
                    case let .failure(error):
                        self.isEventHistoryLoading = false
                        self.eventHistoryError = error.localizedDescription
                    }
                }
            }
            return
        }
        loadRecordingEvents(at: url, sessionID: sessionID, requestID: requestID)
    }

    private func loadRecordingEvents(at url: URL, sessionID: UUID, requestID: UUID) {
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                try RecordingEventHistoryReader.readEvents(at: url, sessionID: sessionID)
            }.result
            guard let self, self.eventHistoryRequestID == requestID else { return }
            self.isEventHistoryLoading = false
            switch result {
            case let .success(history):
                self.selectedRecordingEvents = history.events
                self.isEventHistoryTruncated = history.isTruncated
            case let .failure(error):
                self.eventHistoryError = error.localizedDescription
            }
        }
    }

    private func checkAudioTimeouts() {
        if let calibrationStartedAt,
           now.timeIntervalSince(calibrationStartedAt) > 12 {
            finishCalibration(
                status: L10n.text("Kalibrace selhala: na vybraném kanálu není platný signál 94 dB / 1 kHz.")
            )
            return
        }
        guard isRunning, let audioStartedAt else { return }
        let reference = lastAudioSnapshotAt ?? audioStartedAt
        if now.timeIntervalSince(reference) > 2 {
            stop(status: L10n.text("Zvuková data se zastavila. Zkontrolujte zařízení a stiskněte Spustit vstup."))
        }
    }

    private func consumeAudioHealthForDisplay() {
        let health = engine.takeHealthEvents()
        if health.clippedFrameCount > 0 {
            isClippingDetected = true
        }
        let increment = Self.displayedAudioDropoutIncrement(health)
        if increment > 0 {
            audioDropoutCount += increment
        }
    }

    nonisolated static func displayedAudioDropoutIncrement(_ health: AudioCaptureHealth) -> Int {
        Int(clamping: health.audioDropoutCount + health.renderErrorCount)
    }

    private func finishCalibration(status: String) {
        stopRecording()
        engine.stop()
        calibrationSession = nil
        calibrationStartedAt = nil
        calibrationProgress = nil
        snapshot = .empty
        isRunning = false
        audioStartedAt = nil
        lastAudioSnapshotAt = nil
        self.status = status + " " + L10n.text("Sejměte kalibrátor a stiskněte Spustit vstup.")
    }

    private func chooseRecordingDestination() {
        guard canStartRecording,
              !isPreparingRecording,
              let input = settings.input,
              let calibration = selectedCalibration else { return }
        dismissRecordingError()

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "SPLMan_\(formatter.string(from: Date())).csv"
        panel.title = L10n.text("Uložit záznam měření")
        panel.prompt = L10n.text("Nahrávat")
        let requestID = UUID()
        savePanelRequestID = requestID
        isPreparingRecording = true

        panel.begin { [weak self] response in
            guard let self else { return }
            guard self.savePanelRequestID == requestID else { return }
            self.savePanelRequestID = nil
            self.isPreparingRecording = false
            guard response == .OK, let url = panel.url else { return }
            guard self.canStartRecording,
                  self.settings.input == input,
                  self.selectedCalibration == calibration else { return }
            self.startRecording(at: url, input: input, calibration: calibration)
        }
    }

    private func startRecording(
        at url: URL,
        input: InputSelection,
        calibration: CalibrationRecord
    ) {
        guard canStartRecording,
              settings.input == input,
              selectedCalibration == calibration else { return }

        var initialCompletedSecondCount: UInt64?
        while let stale = engine.takeCompletedSecond() {
            initialCompletedSecondCount = stale.snapshot.completedSecondCount
        }
        let health = engine.takeHealthEvents()
        if health.droppedSecondIntervalCount > 0 {
            initialCompletedSecondCount = nil
        }
        if health.clippedFrameCount > 0 {
            isClippingDetected = true
        }
        let preRecordingDropouts = Self.displayedAudioDropoutIncrement(health)
        if preRecordingDropouts > 0 {
            audioDropoutCount += preRecordingDropouts
        }
        guard let sampleRate = health.sampleRate else {
            presentRecordingError(L10n.text("Záznam nelze spustit: není známá vzorkovací frekvence vstupu."))
            return
        }

        let startedAt = Date()
        let session = MeasurementSession(
            startedAt: startedAt,
            name: recordingMetadata.eventName.isEmpty ? L10n.text("Měření") : recordingMetadata.eventName,
            location: recordingMetadata.location.isEmpty ? L10n.text("Neuvedeno") : recordingMetadata.location,
            note: recordingMetadata.note.nilIfEmpty,
            microphoneID: recordingMetadata.microphoneID.nilIfEmpty,
            deviceUID: input.deviceUID,
            channel: input.channel,
            sampleRate: sampleRate,
            calibrationOffset: calibration.offsetDB,
            calibratedAt: calibration.calibratedAt,
            appVersion: Self.appVersion,
            measurementConfiguration: measurementConfiguration,
            status: .created
        )
        let recordingID = session.id
        let candidate = CSVMeasurementLogger()
        pendingRecordingID = recordingID
        pendingLogger = candidate
        isPreparingRecording = true

        candidate.start(at: url, session: session) { [weak self, weak candidate] result in
            DispatchQueue.main.async {
                guard let self, let candidate else { return }
                guard self.pendingRecordingID == recordingID else {
                    let errorStore = self.recordingErrorStore
                    candidate.stop { result in
                        if case let .failure(error) = result {
                            let message = L10n.format("Soubor záznamu se nepodařilo uzavřít: %@", error.localizedDescription)
                            errorStore.save(message)
                            DispatchQueue.main.async {
                                self.presentRecordingError(message, persist: false)
                            }
                        }
                    }
                    return
                }
                self.pendingRecordingID = nil
                self.pendingLogger = nil
                self.isPreparingRecording = false

                switch result {
                case .success:
                    guard self.canStartRecording,
                          self.settings.input == input,
                          self.selectedCalibration == calibration else {
                        candidate.stop()
                        return
                    }
                    self.logger = candidate
                    self.isRecording = true
                    self.recordingStartedAt = startedAt
                    self.activeSessionID = session.id
                    self.addHistoryEntry(for: session, url: url)
                    let recorder = CompletedSecondRecorder(
                        engine: self.engine,
                        logger: candidate,
                        sessionID: session.id,
                        calibrationOffset: calibration.offsetDB,
                        alarmSettings: self.alarmSettings,
                        initialCompletedSecondCount: initialCompletedSecondCount,
                        sessionStartedAt: startedAt,
                        initialDropoutCount: self.audioDropoutCount,
                        initialClippingDetected: self.isClippingDetected,
                        onUpdate: { [weak self] update in
                            DispatchQueue.main.async {
                                guard let self, self.activeSessionID == session.id else { return }
                                self.audioDropoutCount = update.dropoutCount
                                self.isClippingDetected = update.clippingDetected
                                self.exceededLimits = update.exceededLimits
                            }
                        },
                        onError: { [weak self, weak candidate] error in
                            DispatchQueue.main.async {
                                guard let self, let candidate else { return }
                                self.handleRecorderFailure(error, logger: candidate, sessionID: session.id)
                            }
                        }
                    )
                    self.secondRecorder = recorder
                    recorder.start()
                case let .failure(error):
                    self.presentRecordingError(L10n.format(
                        "Záznam nelze spustit: %@", error.localizedDescription
                    ))
                }
            }
        }
    }

    private func stopRecording(
        waitUntilClosed: Bool = false,
        finalStatus: MeasurementSessionStatus = .completed
    ) {
        savePanelRequestID = nil
        pendingRecordingID = nil
        isPreparingRecording = false
        if let pendingLogger {
            closeLogger(pendingLogger, waitUntilClosed: waitUntilClosed)
        }
        pendingLogger = nil
        secondRecorder?.stop()
        secondRecorder = nil
        let sessionID = activeSessionID
        if let logger {
            closeLogger(
                logger,
                waitUntilClosed: waitUntilClosed,
                finalStatus: finalStatus,
                historyID: sessionID
            )
        }
        logger = nil
        activeSessionID = nil
        isRecording = false
        recordingStartedAt = nil
        exceededLimits = []
    }

    private func closeLogger(
        _ logger: CSVMeasurementLogger,
        waitUntilClosed: Bool,
        finalStatus: MeasurementSessionStatus = .completed,
        historyID: UUID? = nil
    ) {
        let errorStore = recordingErrorStore
        if let historyID {
            finishHistory(historyID, state: historyState(for: finalStatus))
        }
        if waitUntilClosed {
            logger.stop(finalStatus: finalStatus, waitUntilClosed: true) { [weak self] result in
                if case let .failure(error) = result {
                    let message = L10n.format("Soubor záznamu se nepodařilo uzavřít: %@", error.localizedDescription)
                    errorStore.save(message)
                    DispatchQueue.main.async {
                        if let historyID { self?.finishHistory(historyID, state: .failed) }
                        self?.presentRecordingError(message, persist: false)
                    }
                }
            }
            return
        }

        guard !closingLoggers.contains(where: { $0 === logger }) else { return }
        closingLoggers.append(logger)
        logger.stop(finalStatus: finalStatus) { [weak self, weak logger] result in
            let message: String?
            if case let .failure(error) = result {
                let closeMessage = L10n.format("Soubor záznamu se nepodařilo uzavřít: %@", error.localizedDescription)
                message = closeMessage
                errorStore.save(closeMessage)
            } else {
                message = nil
            }
            DispatchQueue.main.async {
                guard let self, let logger else { return }
                self.closingLoggers.removeAll(where: { $0 === logger })
                if let message {
                    if let historyID { self.finishHistory(historyID, state: .failed) }
                    self.presentRecordingError(message, persist: false)
                }
            }
        }
    }

    private func handleRecorderFailure(
        _ error: Error,
        logger: CSVMeasurementLogger,
        sessionID: UUID
    ) {
        guard self.logger === logger, activeSessionID == sessionID else { return }
        let message = L10n.format("Záznam byl zastaven: %@", error.localizedDescription)
        recordingErrorStore.save(message)
        secondRecorder?.stop()
        secondRecorder = nil
        self.logger = nil
        activeSessionID = nil
        isRecording = false
        recordingStartedAt = nil
        exceededLimits = []
        closeLogger(
            logger,
            waitUntilClosed: false,
            finalStatus: .failed,
            historyID: sessionID
        )
        presentRecordingError(message, persist: false)
    }

    private func presentRecordingError(_ message: String, persist: Bool = true) {
        status = message
        recordingError = message
        if persist { recordingErrorStore.save(message) }
    }

    private var measurementConfiguration: [String: String] {
        [
            "displayed_metrics": settings.displayedMetrics.map(\.rawValue).joined(separator: ";"),
            "alarm_enabled": String(alarmSettings.isEnabled),
            "laeq_30_min_limit_db": Self.number(alarmSettings.laeq30MinuteLimit),
            "lcpeak_limit_db": Self.number(alarmSettings.lcPeakLimit)
        ]
    }

    private func addHistoryEntry(for session: MeasurementSession, url: URL) {
        recordingHistory.insert(RecordingHistoryEntry(
            id: session.id,
            startedAt: session.startedAt,
            endedAt: nil,
            eventName: session.name,
            location: session.location,
            filePath: url.path,
            state: .recording
        ), at: 0)
        historyStore.saveHistory(recordingHistory)
    }

    private func finishHistory(_ id: UUID, state: RecordingHistoryEntry.State) {
        guard let index = recordingHistory.firstIndex(where: { $0.id == id }) else { return }
        recordingHistory[index].endedAt = Date()
        recordingHistory[index].state = state
        historyStore.saveHistory(recordingHistory)
    }

    private func historyState(for status: MeasurementSessionStatus) -> RecordingHistoryEntry.State {
        switch status {
        case .completed: .completed
        case .failed: .failed
        case .created, .recording, .paused, .interrupted: .interrupted
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "development"
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
