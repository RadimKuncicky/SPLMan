import Foundation
import X32Kit

/// How one meter bridge section maps to the values of an X32 meter page.
struct X32MeterDefinition {
    let descriptor: MixerMeterSectionDescriptor
    let page: Int
    let firstValue: Int
    /// Name parameter of each strip, in strip order.
    let nameAddresses: [String]

    private var valueCount: Int {
        (descriptor.stripCount ?? 0) * descriptor.barsPerStrip
    }

    /// Converts linear values, with 1.0 at full scale, to dB. Silence becomes
    /// negative infinity, which the bridge draws as an empty bar.
    func levels(from page: [Float]) -> [Float]? {
        guard firstValue + valueCount <= page.count else { return nil }
        return page[firstValue..<(firstValue + valueCount)].map {
            $0 > 0 ? 20 * log10($0) : -Float.infinity
        }
    }
}

/// Adapts `X32Client` to the application's generic mixer layer. X32 strips are
/// mono, with the exception of main LR and the effect returns.
final class X32MixerDriver: MixerDriver {
    static let definitions: [X32MeterDefinition] = {
        // Page 0: 32 channels, 8 aux returns, 8 effect returns, 16 buses, 6 matrices.
        // Page 2: 16 buses, 6 matrices, main L and R, mono, then gain reductions.
        // Page 3: 6 aux sends, then aux and effect returns.
        // Page 4: 32 channels, 8 aux returns, 16 outputs, 16 P16 outputs,
        // 6 aux sends, 2 AES outputs, 2 monitor outputs.
        [
            section(
                "ch",
                L10n.text("Kanály"),
                "CH",
                page: 0,
                first: 0,
                strips: 32,
                nameAddresses: numbered("/ch", through: 32)
            ),
            section(
                "auxin",
                L10n.format("Vstupy %@", "AUX"),
                "AUX IN",
                page: 0,
                first: 32,
                strips: 8,
                nameAddresses: numbered("/auxin", through: 8)
            ),
            section(
                "fxrtn",
                L10n.format("Vstupy %@", "FX"),
                "FX",
                page: 0,
                first: 40,
                strips: 4,
                bars: 2,
                nameAddresses: stride(from: 1, through: 7, by: 2).map {
                    numberedName("/fxrtn", $0)
                }
            ),
            section(
                "bus",
                L10n.text("Busy"),
                "BUS",
                page: 0,
                first: 48,
                strips: 16,
                nameAddresses: numbered("/bus", through: 16)
            ),
            section(
                "mtx",
                L10n.text("Matrix"),
                "MTX",
                page: 0,
                first: 64,
                strips: 6,
                nameAddresses: numbered("/mtx", through: 6)
            ),
            section(
                "main",
                L10n.text("Main"),
                "MAIN",
                page: 2,
                first: 22,
                strips: 1,
                bars: 2,
                nameAddresses: ["/main/st/config/name"]
            ),
            section(
                "mono",
                "M/C",
                "M/C",
                page: 2,
                first: 24,
                strips: 1,
                nameAddresses: ["/main/m/config/name"]
            ),
            section(
                "auxout",
                L10n.format("Výstupy %@", "AUX"),
                "AUX OUT",
                page: 3,
                first: 0,
                strips: 6,
                isVisibleByDefault: false
            ),
            section(
                "out",
                L10n.format("Výstupy %@", "1–16"),
                "OUT",
                page: 4,
                first: 40,
                strips: 16
            ),
            section(
                "p16",
                L10n.format("Výstupy %@", "P16"),
                "P16",
                page: 4,
                first: 56,
                strips: 16,
                isVisibleByDefault: false
            ),
            section(
                "aes",
                L10n.format("Výstupy %@", "AES"),
                "AES",
                page: 4,
                first: 78,
                strips: 2,
                isVisibleByDefault: false
            ),
            section(
                "mon",
                L10n.format("Výstupy %@", "MON"),
                "MON",
                page: 4,
                first: 80,
                strips: 2,
                isVisibleByDefault: false
            )
        ]
    }()

    /// Centre frequencies in Hz of the analyzer's 100 bands, about 1/10 octave
    /// apart, from "Unofficial X32/M32 OSC Remote Protocol" (/meters/15).
    static let rtaBandFrequencies: [Double] = [
        20, 21, 22, 24, 26, 28, 30, 32, 34, 36,
        39, 42, 45, 48, 52, 55, 59, 63, 68, 73,
        78, 84, 90, 96, 103, 110, 118, 127, 136, 146,
        156, 167, 179, 192, 206, 221, 237, 254, 272, 292,
        313, 335, 359, 385, 412, 442, 474, 508, 544, 583,
        625, 670, 718, 769, 825, 884, 947, 1_020, 1_090, 1_170,
        1_250, 1_340, 1_440, 1_540, 1_650, 1_770, 1_890, 2_030, 2_180, 2_330,
        2_500, 2_680, 2_870, 3_080, 3_300, 3_540, 3_790, 4_060, 4_350, 4_670,
        5_000, 5_360, 5_740, 6_160, 6_600, 7_070, 7_580, 8_120, 8_710, 9_330,
        10_000, 10_720, 11_490, 12_310, 13_200, 14_140, 15_160, 16_250, 17_410, 18_660
    ]

    // Analyzer settings, chosen on the console and only ever read.
    static let rtaSourceAddress = "/-prefs/rta/source"
    static let rtaTapAddress = "/-prefs/rta/pos"
    static let rtaDetectorAddress = "/-prefs/rta/det"
    static let rtaParameterAddresses = [rtaSourceAddress, rtaTapAddress, rtaDetectorAddress]

    /// Levels of a page this old are not shown, so a page that stopped arriving
    /// does not look live while other pages keep the connection alive.
    private let staleLevelsAfter: TimeInterval
    private var client: X32Client?
    private var active: [X32MeterDefinition] = []
    private var includeRTA = false
    private var nameTargets: [String: (section: String, strip: Int)] = [:]
    private var namesRevision = 0

    init(staleLevelsAfter: TimeInterval = MixerConnectionController.Timing().staleLevelsAfter) {
        self.staleLevelsAfter = staleLevelsAfter
    }

    /// Levels in dB of every section whose meter page is fresh.
    static func levels(
        for definitions: [X32MeterDefinition],
        pages: [Int: [Float]],
        ages: [Int: TimeInterval],
        staleAfter: TimeInterval
    ) -> [String: [Float]] {
        var levels: [String: [Float]] = [:]
        for definition in definitions {
            guard let age = ages[definition.page],
                  age < staleAfter,
                  let page = pages[definition.page],
                  let sectionLevels = definition.levels(from: page) else { continue }
            levels[definition.descriptor.id] = sectionLevels
        }
        return levels
    }

    /// Shows that the console is alive when only the analyzer is wanted, so a
    /// console that sends no analyzer data keeps its connection. Its values
    /// are not shown.
    static let livenessPage = 2

    /// The meter pages of the requested sections, plus the analyzer's.
    static func meterPages(for active: [X32MeterDefinition], includeRTA: Bool) -> [Int] {
        var pages = Set(active.map(\.page))
        if includeRTA {
            pages.insert(X32Protocol.rtaPage)
            if active.isEmpty {
                pages.insert(livenessPage)
            }
        }
        return pages.sorted()
    }

    /// Analyzer levels, unless the analyzer page is missing or stale; other
    /// pages may keep arriving without it.
    static func rtaFrame(
        levels: [Float]?,
        age: TimeInterval?,
        staleAfter: TimeInterval
    ) -> MixerRTAFrame? {
        guard let levels, !levels.isEmpty, let age, age < staleAfter else { return nil }
        return MixerRTAFrame(levels: levels)
    }

    /// The console's name of an analyzer source: 1 the monitor bus, then
    /// channels, aux inputs, effect returns, buses, matrices, main and mono.
    /// Nil for 0 (no source) and unknown values.
    static func rtaSourceLabel(_ value: Int32) -> String? {
        let number = Int(value)
        switch number {
        case 1:
            return "Monitor"
        case 2...33:
            return String(format: "Ch%02d", number - 1)
        case 34...41:
            return "Aux\(number - 33)"
        case 42...49:
            let side = (number - 42) % 2 == 0 ? "L" : "R"
            return "FX\((number - 42) / 2 + 1)\(side)"
        case 50...65:
            return String(format: "Bus%02d", number - 49)
        case 66...71:
            return "Mtx\(number - 65)"
        case 72:
            return "Main"
        case 73:
            return "Mono"
        default:
            return nil
        }
    }

    static func rtaInfo(parameters: [String: Int32]) -> MixerRTAInfo {
        var info = MixerRTAInfo()
        if let source = parameters[rtaSourceAddress] {
            info.sourceIsNone = source == 0
            info.source = rtaSourceLabel(source)
        }
        switch parameters[rtaTapAddress] {
        case 0?: info.tap = L10n.text("Před EQ")
        case 1?: info.tap = L10n.text("Po EQ")
        default: break
        }
        switch parameters[rtaDetectorAddress] {
        case 0?: info.detector = "RMS"
        case 1?: info.detector = "PEAK"
        default: break
        }
        return info
    }

    /// Accepts only the `/xinfo` reply of the selected console, with the
    /// reply's sender as its address; nil accepts the first console that answers.
    static func discoveryFilter(
        for target: PreferredMixer?
    ) -> ((X32ConsoleInfo, String) -> Bool)? {
        guard let target else { return nil }
        return { info, sender in
            target.matches(
                kind: .behringerX32,
                name: info.name,
                model: info.model,
                serial: "",
                address: sender
            )
        }
    }

    func start(
        address: String?,
        target: PreferredMixer?,
        sections: [MixerMeterSectionDescriptor],
        includeRTA: Bool
    ) {
        stop()
        self.includeRTA = includeRTA
        let requested = Set(sections.map(\.id))
        active = Self.definitions.filter { requested.contains($0.descriptor.id) }
        nameTargets = [:]
        for definition in active {
            for (strip, address) in definition.nameAddresses.enumerated() {
                nameTargets[address] = (definition.descriptor.id, strip)
            }
        }
        let client = X32Client(
            address: address,
            meterPages: Self.meterPages(for: active, includeRTA: includeRTA),
            nameAddresses: active.flatMap(\.nameAddresses),
            parameterAddresses: includeRTA ? Self.rtaParameterAddresses : [],
            discoveryFilter: address == nil ? Self.discoveryFilter(for: target) : nil
        )
        self.client = client
        client.start()
    }

    func poll() -> MixerDriverUpdate {
        guard let client else { return MixerDriverUpdate(state: .failed) }
        let snapshot = client.snapshot()
        switch snapshot.state {
        case .connecting:
            return MixerDriverUpdate(state: .connecting)
        case .failed:
            return MixerDriverUpdate(state: .failed)
        case .connected:
            break
        }

        var update = MixerDriverUpdate(
            state: .connected(MixerIdentity(
                address: snapshot.address ?? "",
                name: snapshot.name.isEmpty ? snapshot.model : snapshot.name,
                model: snapshot.model,
                firmware: snapshot.firmware
            )),
            secondsSinceMeterData: snapshot.secondsSinceMeterData,
            levels: Self.levels(
                for: active,
                pages: snapshot.meterPages,
                ages: snapshot.secondsSinceMeterPage,
                staleAfter: staleLevelsAfter
            )
        )
        if includeRTA {
            update.rta = Self.rtaFrame(
                levels: snapshot.rtaLevels,
                age: snapshot.secondsSinceMeterPage[X32Protocol.rtaPage],
                staleAfter: staleLevelsAfter
            )
            update.rtaInfo = Self.rtaInfo(parameters: snapshot.parameters)
        }

        if snapshot.namesRevision != namesRevision {
            namesRevision = snapshot.namesRevision
            for (address, target) in nameTargets {
                if let name = snapshot.names[address] {
                    update.names[target.section, default: [:]][target.strip] = name
                }
            }
        }
        return update
    }

    func stop() {
        client?.stop()
        client = nil
        namesRevision = 0
    }

    private static func section(
        _ id: String,
        _ title: String,
        _ shortTitle: String,
        page: Int,
        first: Int,
        strips: Int,
        bars: Int = 1,
        isVisibleByDefault: Bool = true,
        nameAddresses: [String] = []
    ) -> X32MeterDefinition {
        X32MeterDefinition(
            descriptor: MixerMeterSectionDescriptor(
                id: id,
                title: title,
                shortTitle: shortTitle,
                stripCount: strips,
                barsPerStrip: bars,
                isVisibleByDefault: isVisibleByDefault
            ),
            page: page,
            firstValue: first,
            nameAddresses: nameAddresses
        )
    }

    private static func numbered(_ prefix: String, through count: Int) -> [String] {
        (1...count).map { numberedName(prefix, $0) }
    }

    private static func numberedName(_ prefix: String, _ number: Int) -> String {
        prefix + "/" + String(format: "%02d", number) + "/config/name"
    }
}
