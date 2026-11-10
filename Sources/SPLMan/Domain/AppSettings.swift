import Foundation

struct InputSelection: Codable, Equatable {
    var deviceUID: String
    var channel: Int
}

struct CalibrationKey: Hashable, Codable {
    let deviceUID: String
    let channel: Int
}

struct CalibrationRecord: Codable, Equatable {
    let offsetDB: Double
    let calibratedAt: Date
}

enum SpectrogramFrequencyRange: String, CaseIterable, Codable, Identifiable {
    case full
    case focused
    case voice

    var id: String { rawValue }

    var lowerFrequency: Double {
        switch self {
        case .full: 20
        case .focused: 50
        case .voice: 100
        }
    }

    var upperFrequency: Double {
        switch self {
        case .full: 20_000
        case .focused: 10_000
        case .voice: 5_000
        }
    }

    var title: String {
        switch self {
        case .full: L10n.text("20 Hz – 20 kHz")
        case .focused: L10n.text("50 Hz – 10 kHz")
        case .voice: L10n.text("100 Hz – 5 kHz")
        }
    }
}

enum SpectrogramHistoryDuration: Int, CaseIterable, Codable, Identifiable {
    case short = 10
    case medium = 30
    case long = 60

    var id: Int { rawValue }
    var title: String { L10n.format("%d s", Int32(rawValue)) }
}

enum SpectrogramIntensity: String, CaseIterable, Codable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: L10n.text("Nízká")
        case .medium: L10n.text("Střední")
        case .high: L10n.text("Vysoká")
        }
    }

    var opacity: Double {
        switch self {
        case .low: 0.18
        case .medium: 0.26
        case .high: 0.34
        }
    }
}

enum SpectrogramPalette: String, CaseIterable, Codable, Identifiable {
    case current
    case rgb
    case smaartInspired

    var id: String { rawValue }

    var title: String {
        switch self {
        case .current: L10n.text("Modrá–tyrkysová–žlutá")
        case .rgb: L10n.text("Modrá–zelená–červená")
        case .smaartInspired: L10n.text("Duhová (styl Smaart)")
        }
    }
}

/// Fractional-octave smoothing of the transfer-function trace. The raw value
/// is the number of smoothing bands per octave.
enum TransferFunctionSmoothing: Int, CaseIterable, Codable, Identifiable {
    case oneFortyEighth = 48
    case oneTwentyFourth = 24
    case oneTwelfth = 12
    case oneSixth = 6
    case oneThird = 3
    case oneOctave = 1

    static let `default`: TransferFunctionSmoothing = .oneSixth

    var id: Int { rawValue }
    var bandsPerOctave: Int { rawValue }

    var title: String {
        self == .oneOctave
            ? L10n.text("1 oktáva")
            : L10n.format("1/%d oktávy", Int32(rawValue))
    }
}

enum AnalysisDisplayMode: String, CaseIterable, Codable, Identifiable {
    case spectrogram
    case transferFunction
    case combined
    case meterBridge
    /// The mixing console's real-time analyzer.
    case rta
    case wireless
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spectrogram: L10n.text("Spektrogram")
        case .transferFunction: L10n.text("Přenosová charakteristika")
        case .combined: L10n.text("Přenosová charakteristika a spektrogram")
        case .meterBridge: L10n.text("Meter bridge")
        case .rta: L10n.text("RTA mixpultu")
        case .wireless: L10n.text("Bezdrátové mikrofony")
        case .none: L10n.text("Nic")
        }
    }

    var usesAudioAnalysis: Bool {
        showsSpectrogram || showsTransferFunction
    }

    var showsSpectrogram: Bool {
        self == .spectrogram || self == .combined
    }

    var showsTransferFunction: Bool {
        self == .transferFunction || self == .combined
    }

    var next: AnalysisDisplayMode {
        switch self {
        case .spectrogram: .transferFunction
        case .transferFunction: .combined
        case .combined: .meterBridge
        case .meterBridge: .rta
        case .rta: .wireless
        case .wireless: .none
        case .none: .spectrogram
        }
    }
}

struct SpectrogramSettings: Codable, Equatable {
    static let defaultUpperLevelDB = 100.0
    static let defaultDynamicRangeDB = 50.0
    static let defaultTransferFunctionRangeDB = 12.0
    static let allowedUpperLevelDB = 40.0...140.0
    static let allowedDynamicRangeDB = 10.0...100.0
    static let allowedTransferFunctionRangeDB = 3.0...60.0

    var displayMode: AnalysisDisplayMode = .none
    var frequencyRange: SpectrogramFrequencyRange = .full
    var historyDuration: SpectrogramHistoryDuration = .medium
    var intensity: SpectrogramIntensity = .medium
    var palette: SpectrogramPalette = .current
    var upperLevelDB = defaultUpperLevelDB
    var dynamicRangeDB = defaultDynamicRangeDB
    var transferFunctionRangeDB = defaultTransferFunctionRangeDB
    var transferFunctionSmoothing: TransferFunctionSmoothing = .default
    var referenceChannel: Int?

    private enum CodingKeys: String, CodingKey {
        case displayMode
        // Kept for decoding settings saved by versions before displayMode.
        case isEnabled
        case frequencyRange
        case historyDuration
        case intensity
        case palette
        case upperLevelDB
        case dynamicRangeDB
        case transferFunctionRangeDB
        case transferFunctionSmoothing
        case isTransferFunctionEnabled
        case referenceChannel
    }

    init(
        displayMode: AnalysisDisplayMode = .none,
        frequencyRange: SpectrogramFrequencyRange = .full,
        historyDuration: SpectrogramHistoryDuration = .medium,
        intensity: SpectrogramIntensity = .medium,
        palette: SpectrogramPalette = .current,
        upperLevelDB: Double = defaultUpperLevelDB,
        dynamicRangeDB: Double = defaultDynamicRangeDB,
        transferFunctionRangeDB: Double = defaultTransferFunctionRangeDB,
        transferFunctionSmoothing: TransferFunctionSmoothing = .default,
        referenceChannel: Int? = nil
    ) {
        self.displayMode = displayMode
        self.frequencyRange = frequencyRange
        self.historyDuration = historyDuration
        self.intensity = intensity
        self.palette = palette
        self.upperLevelDB = Self.validatedUpperLevel(upperLevelDB)
        self.dynamicRangeDB = Self.validatedDynamicRange(dynamicRangeDB)
        self.transferFunctionRangeDB = Self.validatedTransferFunctionRange(
            transferFunctionRangeDB
        )
        self.transferFunctionSmoothing = transferFunctionSmoothing
        self.referenceChannel = referenceChannel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An unknown mode (for example from a newer version) falls back to the
        // flags every version writes, instead of resetting every analysis setting.
        if let displayMode = try? container.decodeIfPresent(
            AnalysisDisplayMode.self,
            forKey: .displayMode
        ) {
            self.displayMode = displayMode
        } else {
            let isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
            let isTransferFunctionEnabled = try container.decodeIfPresent(
                Bool.self,
                forKey: .isTransferFunctionEnabled
            ) ?? false
            if !isEnabled {
                self.displayMode = .none
            } else if isTransferFunctionEnabled {
                self.displayMode = .transferFunction
            } else {
                self.displayMode = .spectrogram
            }
        }
        frequencyRange = try container.decodeIfPresent(
            SpectrogramFrequencyRange.self,
            forKey: .frequencyRange
        ) ?? .full
        historyDuration = try container.decodeIfPresent(
            SpectrogramHistoryDuration.self,
            forKey: .historyDuration
        ) ?? .medium
        intensity = try container.decodeIfPresent(
            SpectrogramIntensity.self,
            forKey: .intensity
        ) ?? .medium
        palette = try container.decodeIfPresent(
            SpectrogramPalette.self,
            forKey: .palette
        ) ?? .current
        upperLevelDB = Self.validatedUpperLevel(
            try container.decodeIfPresent(Double.self, forKey: .upperLevelDB)
                ?? Self.defaultUpperLevelDB
        )
        dynamicRangeDB = Self.validatedDynamicRange(
            try container.decodeIfPresent(Double.self, forKey: .dynamicRangeDB)
                ?? Self.defaultDynamicRangeDB
        )
        transferFunctionRangeDB = Self.validatedTransferFunctionRange(
            try container.decodeIfPresent(Double.self, forKey: .transferFunctionRangeDB)
                ?? Self.defaultTransferFunctionRangeDB
        )
        // An unknown smoothing (for example from a newer version) falls back
        // to the default instead of resetting every analysis setting.
        transferFunctionSmoothing = (try? container.decodeIfPresent(
            TransferFunctionSmoothing.self,
            forKey: .transferFunctionSmoothing
        )) ?? .default
        referenceChannel = try container.decodeIfPresent(Int.self, forKey: .referenceChannel)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displayMode, forKey: .displayMode)
        try container.encode(displayMode != .none, forKey: .isEnabled)
        try container.encode(displayMode.showsTransferFunction, forKey: .isTransferFunctionEnabled)
        try container.encode(frequencyRange, forKey: .frequencyRange)
        try container.encode(historyDuration, forKey: .historyDuration)
        try container.encode(intensity, forKey: .intensity)
        try container.encode(palette, forKey: .palette)
        try container.encode(upperLevelDB, forKey: .upperLevelDB)
        try container.encode(dynamicRangeDB, forKey: .dynamicRangeDB)
        try container.encode(transferFunctionRangeDB, forKey: .transferFunctionRangeDB)
        try container.encode(transferFunctionSmoothing, forKey: .transferFunctionSmoothing)
        try container.encodeIfPresent(referenceChannel, forKey: .referenceChannel)
    }

    static func validatedUpperLevel(_ value: Double) -> Double {
        guard value.isFinite else { return defaultUpperLevelDB }
        return min(allowedUpperLevelDB.upperBound, max(allowedUpperLevelDB.lowerBound, value))
    }

    static func validatedDynamicRange(_ value: Double) -> Double {
        guard value.isFinite else { return defaultDynamicRangeDB }
        return min(
            allowedDynamicRangeDB.upperBound,
            max(allowedDynamicRangeDB.lowerBound, value)
        )
    }

    static func validatedTransferFunctionRange(_ value: Double) -> Double {
        guard value.isFinite else { return defaultTransferFunctionRangeDB }
        return min(
            allowedTransferFunctionRangeDB.upperBound,
            max(allowedTransferFunctionRangeDB.lowerBound, value)
        )
    }
}

struct PersistedSettings: Codable, Equatable {
    var input: InputSelection?
    var displayedMetrics: [Metric] = [.laeq1, .aSlow, .laeq10]
    var calibrations: [CalibrationKey: CalibrationRecord] = [:]
    var thresholds = VisualThresholds()
    var spectrogram = SpectrogramSettings()
    var mixer = MixerSettings()
    var wireless = WirelessSettings()

    private enum CodingKeys: String, CodingKey {
        case input
        case displayedMetrics
        case calibrations
        case thresholds
        case spectrogram
        case mixer
        case wireless
    }

    init() {}

    /// Each field decodes independently, so an unreadable value (for example
    /// an enum case written by a newer version) resets only that field and
    /// never discards the stored calibrations.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = (try? container.decodeIfPresent(InputSelection.self, forKey: .input))
        displayedMetrics = (try? container.decodeIfPresent([Metric].self, forKey: .displayedMetrics))
            ?? [.laeq1, .aSlow, .laeq10]
        calibrations = (try? container.decodeIfPresent(
            [CalibrationKey: CalibrationRecord].self,
            forKey: .calibrations
        )) ?? [:]
        thresholds = (try? container.decodeIfPresent(VisualThresholds.self, forKey: .thresholds))
            ?? VisualThresholds()
        spectrogram = (try? container.decodeIfPresent(SpectrogramSettings.self, forKey: .spectrogram))
            ?? SpectrogramSettings()
        mixer = (try? container.decodeIfPresent(MixerSettings.self, forKey: .mixer))
            ?? MixerSettings()
        wireless = (try? container.decodeIfPresent(WirelessSettings.self, forKey: .wireless))
            ?? WirelessSettings()
    }
}

final class SettingsStore {
    private let defaults: UserDefaults
    private let key = "SPLMan.settings.v1"
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PersistedSettings {
        guard let data = defaults.data(forKey: key) else { return PersistedSettings() }
        guard let settings = try? decoder.decode(PersistedSettings.self, from: data) else {
            // Keep the unreadable blob so the next save cannot destroy the
            // only copy of the user's calibrations.
            defaults.set(data, forKey: Self.unreadableBackupKey)
            return PersistedSettings()
        }
        return settings
    }

    static let unreadableBackupKey = "SPLMan.settings.v1.unreadable"

    func save(_ settings: PersistedSettings) {
        guard let data = try? encoder.encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
