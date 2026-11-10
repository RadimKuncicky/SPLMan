import Foundation
import WingKit

/// How one meter bridge section maps to the WING's meter reports.
struct WingMeterDefinition {
    let descriptor: MixerMeterSectionDescriptor
    let meters: [WingMeter]
    let wordsPerStrip: Int
    let leftWord: Int
    /// Nil for a physical connector, which has a single meter.
    let rightWord: Int?
    /// Name node of each strip, in strip order.
    let nameIDs: [Int32]

    /// Values are signed 16-bit in 1/256 dB. Reports contain whole strips, but a
    /// short one must not read past its end.
    func levels(from words: [Int16]) -> [Float] {
        let reported = words.count / wordsPerStrip
        let strips = descriptor.stripCount.map { min($0, reported) } ?? reported
        var levels: [Float] = []
        levels.reserveCapacity(strips * descriptor.barsPerStrip)
        for strip in 0..<strips {
            let first = strip * wordsPerStrip
            levels.append(Float(words[first + leftWord]) / 256)
            if let rightWord {
                levels.append(Float(words[first + rightWord]) / 256)
            }
        }
        return levels
    }
}

/// Adapts `WingClient` to the application's generic mixer layer.
final class WingMixerDriver: MixerDriver {
    static let definitions: [WingMeterDefinition] = {
        // Reports of strips hold input, output, gate and dynamics values; the
        // bridge shows the output pair. DCA reports hold pre and post fader pairs.
        var definitions = [
            strip("ch", L10n.text("Kanály"), "CH", kind: .channel, count: 40, nameIDs: channelNameIDs),
            strip("aux", L10n.text("Aux"), "AUX", kind: .aux, count: 8, nameIDs: auxNameIDs),
            strip("bus", L10n.text("Busy"), "BUS", kind: .bus, count: 16, nameIDs: busNameIDs),
            strip("main", L10n.text("Main"), "MAIN", kind: .main, count: 4, nameIDs: mainNameIDs),
            strip("mtx", L10n.text("Matrix"), "MTX", kind: .matrix, count: 8, nameIDs: matrixNameIDs),
            strip(
                "dca",
                L10n.text("DCA"),
                "DCA",
                kind: .dca,
                count: 8,
                wordsPerStrip: 4,
                nameIDs: dcaNameIDs
            )
        ]
        for (index, group) in inputGroups.enumerated() {
            definitions.append(connectorGroup(
                "in.\(group)",
                L10n.format("Vstupy %@", group),
                "IN \(group)",
                kind: .source,
                index: index
            ))
        }
        for (index, group) in outputGroups.enumerated() {
            definitions.append(connectorGroup(
                "out.\(group)",
                L10n.format("Výstupy %@", group),
                "OUT \(group)",
                kind: .output,
                index: index
            ))
        }
        return definitions
    }()

    /// The console sends 120 analyzer bands, but their frequencies are not
    /// documented. ASSUMPTION: 1/12 octave from 20 Hz, so that 10 octaves cover
    /// 20 Hz to 20 kHz. Verify against a console before relying on the axis.
    static let rtaBandCount = 120
    static let rtaBandFrequencies: [Double] = (0..<rtaBandCount).map {
        20 * pow(2, Double($0) / 12)
    }

    // Parameter hashes of the analyzer settings, chosen on the console and only
    // ever read, from the same property map as the name nodes below.
    /// /cfg/rta/rtasrc, an integer from 0 to 76.
    static let rtaSourceNode: Int32 = 792_206_572
    /// /cfg/rta/rtatap, text such as PREEQ or POSTEQ.
    static let rtaTapNode: Int32 = -230_889_283
    /// /cfg/rta/rtadet, text: PEAK, RMS or AVG.
    static let rtaDetectorNode: Int32 = 3_015_320
    static let rtaNodes = [rtaSourceNode, rtaTapNode, rtaDetectorNode]

    private var client: WingClient?
    private var active: [WingMeterDefinition] = []
    private var includeRTA = false
    /// Index of the analyzer's group in the client's reports.
    private var rtaGroup: Int?
    private var nameTargets: [Int32: (section: String, strip: Int)] = [:]
    private var namesRevision = 0

    /// Shows that the console is alive when only the analyzer is wanted, so a
    /// console that sends no analyzer data keeps its connection. Main strips
    /// exist on every model; their values are not shown.
    static let livenessGroup = WingMeterGroup(
        meters: (0..<4).map { WingMeter(kind: .main, index: UInt8($0)) },
        isRequired: true
    )

    /// One group per section, in section order, so that a section's group index
    /// is its index in `active`. The analyzer's group comes last, after the
    /// liveness group when there is no section.
    static func meterGroups(
        for active: [WingMeterDefinition],
        includeRTA: Bool
    ) -> (groups: [WingMeterGroup], rtaGroup: Int?) {
        var groups: [WingMeterGroup] = active.map { definition in
            // Strips exist on every model; connectors depend on its cards.
            WingMeterGroup(
                meters: definition.meters,
                isRequired: definition.descriptor.stripCount != nil
            )
        }
        guard includeRTA else { return (groups, nil) }
        if active.isEmpty {
            groups.append(livenessGroup)
        }
        groups.append(WingMeterGroup(meters: [.rta], isRequired: false))
        return (groups, groups.count - 1)
    }

    /// Levels of the sections, from the groups with the same index; groups
    /// after the sections are not shown.
    static func levels(
        for active: [WingMeterDefinition],
        reports: [[Int16]]
    ) -> (levels: [String: [Float]], stripCounts: [String: Int]) {
        var levels: [String: [Float]] = [:]
        var stripCounts: [String: Int] = [:]
        for (group, definition) in active.enumerated() where group < reports.count {
            let words = reports[group]
            guard !words.isEmpty else { continue }
            let sectionLevels = definition.levels(from: words)
            levels[definition.descriptor.id] = sectionLevels
            if definition.descriptor.stripCount == nil {
                stripCounts[definition.descriptor.id] =
                    sectionLevels.count / definition.descriptor.barsPerStrip
            }
        }
        return (levels, stripCounts)
    }

    /// Analyzer levels of the RTA group's words, in 1/256 dB like other meters.
    /// Nil when the console sent none; more than the expected bands are cut off.
    static func rtaFrame(from words: [Int16]) -> MixerRTAFrame? {
        guard !words.isEmpty else { return nil }
        return MixerRTAFrame(levels: words.prefix(rtaBandCount).map { Float($0) / 256 })
    }

    /// The strip an analyzer source index names. DERIVED, not documented for
    /// this parameter: 1 to 76 are taken to be the console's 76 strips in their
    /// usual order (40 channels, 8 aux, 16 buses, 4 mains, 8 matrices), as for
    /// the selected strip. Nil for 0 (no source) and unknown values.
    static func rtaSourceLabel(_ index: Int32) -> String? {
        let number = Int(index)
        switch number {
        case 1...40: return "CH \(number)"
        case 41...48: return "AUX \(number - 40)"
        case 49...64: return "BUS \(number - 48)"
        case 65...68: return "MAIN \(number - 64)"
        case 69...76: return "MTX \(number - 68)"
        default: return nil
        }
    }

    /// Tap points are shown as the console names them, except the equalizer
    /// taps, which the application names in the user's language.
    static func rtaTapLabel(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.uppercased() {
        case "": return nil
        case "PREEQ": return L10n.text("Před EQ")
        case "POSTEQ": return L10n.text("Po EQ")
        default: return trimmed
        }
    }

    static func rtaInfo(values: [Int32: WingNodeValue.Value]) -> MixerRTAInfo {
        var info = MixerRTAInfo()
        switch values[rtaSourceNode] {
        case .integer(let index)?:
            info.sourceIsNone = index == 0
            info.source = rtaSourceLabel(index)
        case .text(let text)?:
            // Not expected for this node; shown as received.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            info.source = trimmed.isEmpty ? nil : trimmed
        case nil:
            break
        }
        if case .text(let text)? = values[rtaTapNode] {
            info.tap = rtaTapLabel(text)
        }
        if case .text(let text)? = values[rtaDetectorNode] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            info.detector = trimmed.isEmpty ? nil : trimmed
        }
        return info
    }

    /// Accepts only the discovery reply of the selected console; nil accepts
    /// the first console that answers.
    static func discoveryFilter(for target: PreferredMixer?) -> ((WingConsoleInfo) -> Bool)? {
        guard let target else { return nil }
        return { info in
            target.matches(
                kind: .behringerWing,
                name: info.name,
                model: info.model,
                serial: info.serial,
                address: info.ip
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
            for (strip, id) in definition.nameIDs.enumerated() {
                nameTargets[id] = (definition.descriptor.id, strip)
            }
        }
        let groups = Self.meterGroups(for: active, includeRTA: includeRTA)
        rtaGroup = groups.rtaGroup
        let client = WingClient(
            address: address,
            meterGroups: groups.groups,
            nameNodes: active.flatMap(\.nameIDs),
            valueNodes: includeRTA ? Self.rtaNodes : [],
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
                name: snapshot.console?.name ?? "",
                model: snapshot.console?.model ?? "",
                firmware: snapshot.console?.firmware ?? ""
            )),
            secondsSinceMeterData: snapshot.secondsSinceMeterData
        )
        let sectionLevels = Self.levels(for: active, reports: snapshot.reports)
        update.levels = sectionLevels.levels
        update.stripCounts = sectionLevels.stripCounts
        if includeRTA {
            // An absent or empty group has no levels.
            if let group = rtaGroup, group < snapshot.reports.count {
                update.rta = Self.rtaFrame(from: snapshot.reports[group])
            }
            update.rtaInfo = Self.rtaInfo(values: snapshot.values)
        }

        if snapshot.namesRevision != namesRevision {
            namesRevision = snapshot.namesRevision
            for (id, target) in nameTargets {
                if let name = snapshot.names[id] {
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

    private static func strip(
        _ id: String,
        _ title: String,
        _ shortTitle: String,
        kind: WingMeter.Kind,
        count: Int,
        wordsPerStrip: Int = 8,
        nameIDs: [Int32]
    ) -> WingMeterDefinition {
        WingMeterDefinition(
            descriptor: MixerMeterSectionDescriptor(
                id: id,
                title: title,
                shortTitle: shortTitle,
                stripCount: count,
                barsPerStrip: 2,
                isVisibleByDefault: true
            ),
            meters: (0..<count).map { WingMeter(kind: kind, index: UInt8($0)) },
            wordsPerStrip: wordsPerStrip,
            leftWord: 2,
            rightWord: 3,
            nameIDs: nameIDs
        )
    }

    /// A group holds all its connectors, and its length tells how many there are.
    /// Only the console's local connectors are shown by default.
    private static func connectorGroup(
        _ id: String,
        _ title: String,
        _ shortTitle: String,
        kind: WingMeter.Kind,
        index: Int
    ) -> WingMeterDefinition {
        WingMeterDefinition(
            descriptor: MixerMeterSectionDescriptor(
                id: id,
                title: title,
                shortTitle: shortTitle,
                stripCount: nil,
                barsPerStrip: 1,
                isVisibleByDefault: index == 0
            ),
            meters: [WingMeter(kind: kind, index: UInt8(index))],
            wordsPerStrip: 1,
            leftWord: 0,
            rightWord: nil,
            nameIDs: []
        )
    }

    // Connector groups in the order of the console's parameter tree.
    private static let inputGroups = [
        "LCL", "AUX", "A", "B", "C", "SC", "USB", "CRD", "MOD", "PLAY", "AES", "USR", "OSC"
    ]
    private static let outputGroups = [
        "LCL", "AUX", "A", "B", "C", "SC", "USB", "CRD", "MOD", "REC", "AES"
    ]

    // Parameter hashes of the console's name nodes, taken from the property map
    // published with libwing 1.0.5 (https://github.com/dannyfiresnake/libwing).

    // /ch/1...40/$name
    private static let channelNameIDs: [Int32] = [
        -1667206318, -639228797, 404268486, 1908890256, 1297550679, 503451486, 1579496311, -521684559,
        1688316887, -1654940678, 1170785004, -1304804554, -1750134632, 1082129122, -1401308908, -1846652258,
        985629248, 1106230218, -1935574852, 705442461, 262958075, 323152785, 569290655, -283433675,
        445212499, 23512841, 64725559, 290191341, 368681995, -1473457397, -500978631, -1125000817,
        -700614051, 85742067, -1209368287, -784979753, -266007867, -407604517, -1133862711, 1872148037
    ]
    // /aux/1...8/$name
    private static let auxNameIDs: [Int32] = [
        -1919313511, 1930156003, 1504955645, -2040375993, 1830044609, 1386470219, -2137869467, -1912399697
    ]
    // /bus/1...16/$name
    private static let busNameIDs: [Int32] = [
        -1989432348, -1113752438, -1286463912, -2069569218, -1193863892, -698783534, 1851035648, -2050718074,
        -1070165068, 1463836601, 1236573019, 239798110, -721272147, -240480598, 707147762, -1675951100
    ]
    // /main/1...4/$name
    private static let mainNameIDs: [Int32] = [
        2111415944, 2068454003, -1472462138, 1169987267
    ]
    // /mtx/1...8/$name
    private static let matrixNameIDs: [Int32] = [
        1130414855, -2040060495, -1793970301, 1000807917, -1495978305, -1917644759, 1566554171, 1037039941
    ]
    // /dca/1...8/name
    private static let dcaNameIDs: [Int32] = [
        1092527793, 2012060424, -1658066198, -1559619652, 1765487758, -1590984688, -1469478094, 1852350468
    ]
}
