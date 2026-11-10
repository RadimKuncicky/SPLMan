import CoreGraphics
import Foundation
import WingKit
import X32Kit

enum MixerTests {
    private final class FakeDriver: MixerDriver {
        var update = MixerDriverUpdate(state: .connecting)
        var startedAddress: String??
        var stopCount = 0

        func start(address: String?, sections: [MixerMeterSectionDescriptor]) {
            startedAddress = .some(address)
        }

        func poll() -> MixerDriverUpdate { update }

        func stop() { stopCount += 1 }
    }

    static func run() -> [String] {
        var failures: [String] = []
        testScale(&failures)
        testWingDefinitions(&failures)
        testWingRequests(&failures)
        testWingReplies(&failures)
        testWingStream(&failures)
        testX32Protocol(&failures)
        testX32Definitions(&failures)
        testX32Endpoint(&failures)
        testX32Client(&failures)
        testX32StaleLevels(&failures)
        testLayout(&failures)
        testSettings(&failures)
        testSectionVisibilityByKind(&failures)
        testUnknownDisplayMode(&failures)
        testConnection(&failures)
        testConnectionWithoutAttempt(&failures)
        return failures
    }

    private static func testScale(_ failures: inout [String]) {
        typealias Scale = MixerMeterScale
        func zones(_ level: Double) -> [Scale.Zone] {
            Scale.segments(levelDB: level).map(\.zone)
        }
        if !zones(-60).isEmpty || !zones(-.infinity).isEmpty {
            failures.append("Mixer meter drew a level at the bottom of its range")
        }
        if zones(-30) != [.green] || zones(-18) != [.green] {
            failures.append("Mixer meter must stay green up to -18 dB")
        }
        if zones(-17.9) != [.green, .yellow] || zones(-0.1) != [.green, .yellow] {
            failures.append("Mixer meter must be yellow from -18 dB to 0 dB")
        }
        if zones(0) != [.green, .yellow, .red] {
            failures.append("Mixer meter must be red from 0 dB")
        }
        if let red = Scale.segments(levelDB: 0).last, red.upper <= red.lower {
            failures.append("Mixer meter red zone is not visible at exactly 0 dB")
        }
        if Scale.segments(levelDB: 40).last?.upper != 1 {
            failures.append("Mixer meter exceeded the top of its bar")
        }
    }

    private static func testWingDefinitions(_ failures: inout [String]) {
        let definitions = WingMixerDriver.definitions
        let identifiers = definitions.map(\.descriptor.id)
        if Set(identifiers).count != identifiers.count {
            failures.append("WING meter sections do not have unique identifiers")
        }
        var nameIDs: [Int32] = []
        for definition in definitions {
            guard let count = definition.descriptor.stripCount else { continue }
            if definition.nameIDs.count != count || definition.meters.count != count {
                failures.append("WING section \(definition.descriptor.id) has a wrong strip count")
            }
            if definition.descriptor.barsPerStrip != 2 {
                failures.append("WING strip section \(definition.descriptor.id) is not stereo")
            }
            nameIDs += definition.nameIDs
        }
        if Set(nameIDs).count != nameIDs.count {
            failures.append("WING strip name identifiers are not unique")
        }

        guard let channels = definitions.first(where: { $0.descriptor.id == "ch" }),
              let inputs = definitions.first(where: { $0.descriptor.id == "in.LCL" }) else {
            failures.append("WING channel or local input section is missing")
            return
        }
        // input L/R, output L/R, gate key/gain, dynamics key/gain
        let words: [Int16] = [0, 0, -256, -2_560, 0, 0, 0, 0, 0, 0, 256, 512, 0, 0, 0, 0, 7]
        if channels.levels(from: words) != [-1, -10, 1, 2] {
            failures.append("WING strip levels were not read from the output pair")
        }
        if inputs.levels(from: [-5_120, 128]) != [-20, 0.5] {
            failures.append("WING connector levels were decoded incorrectly")
        }
        if !inputs.descriptor.isVisibleByDefault
            || definitions.first(where: { $0.descriptor.id == "in.A" })?.descriptor.isVisibleByDefault != false {
            failures.append("Only local connector groups should be shown by default")
        }
    }

    /// Expected bytes are the examples in the "WING Remote Protocols" document,
    /// plus the escaping its sample routines define.
    private static func testWingRequests(_ failures: inout [String]) {
        let port: [UInt8] = [0xdf, 0xd3, 0xd3, 0x37, 0x37, 0xdf, 0xd1]
        if WingProtocol.meterPort(0x3737) != port {
            failures.append("WING meter port request differs from the protocol example")
        }
        let request: [UInt8] = [
            0xdf, 0xd3, 0xd4, 0x00, 0x00, 0x00, 0x02, 0xdc, 0xa0, 0x01, 0xde, 0xdf, 0xd1
        ]
        let channel2 = WingMeter(kind: .channel, index: 1)
        if WingProtocol.meterRequest(reportID: 2, meters: [channel2]) != request {
            failures.append("WING meter request differs from the protocol example")
        }
        let renewal: [UInt8] = [0xdf, 0xd3, 0xd4, 0x00, 0x00, 0x00, 0x02, 0xdf, 0xd1]
        if WingProtocol.meterRenewal(reportID: 2) != renewal {
            failures.append("WING meter renewal differs from the protocol example")
        }
        if WingProtocol.split([1, 2, 3], lengths: [2, 0, 1]) != [[1, 2], [], [3]] {
            failures.append("A combined WING report was not split into its groups")
        }
        if WingProtocol.split([1, 2, 3], lengths: [2]) != nil {
            failures.append("A WING report that does not match its groups was accepted")
        }
        let escapedPort: [UInt8] = [0xdf, 0xd3, 0xd3, 0xdf, 0xde, 0x12, 0xdf, 0xd1]
        if WingProtocol.meterPort(0xdf12) != escapedPort {
            failures.append("WING escape byte in a port number was not escaped")
        }
        let nodeRequest: [UInt8] = [0xd7, 0x02, 0xdf, 0xde, 0xaf, 0x0e, 0xdc]
        if WingProtocol.nodeDataRequest(node: Int32(bitPattern: 0x02df_af0e)) != nodeRequest {
            failures.append("WING escape byte in a node hash was not escaped")
        }
    }

    private static func testWingReplies(_ failures: inout [String]) {
        let info = WingConsoleInfo(
            discoveryReply: "WING,192.168.1.19,Stage,wing-compact,S123,3.0.5"
        )
        if info?.ip != "192.168.1.19" || info?.name != "Stage" || info?.firmware != "3.0.5" {
            failures.append("WING discovery reply was not read")
        }
        if WingConsoleInfo(discoveryReply: "OTHER,1,2,3,4,5") != nil
            || WingConsoleInfo(discoveryReply: "WING,1") != nil {
            failures.append("An invalid WING discovery reply was accepted")
        }

        let report = WingMeterReport(packet: [0, 0, 0, 2, 0xff, 0x00, 0x01, 0x00, 0x07])
        if report?.reportID != 2 || report?.words != [-256, 256] {
            failures.append("WING meter report was not read as big-endian values")
        }
        if WingMeterReport(packet: [0, 0, 2]) != nil {
            failures.append("A truncated WING meter report was accepted")
        }
    }

    private static func testWingStream(_ failures: inout [String]) {
        var parser = WingStreamParser()
        let node = Int32(bitPattern: 0x02df_af0e)
        func texts(_ bytes: [UInt8]) -> [String] {
            let values = parser.consume(bytes)
            if values.contains(where: { $0.node != node }) {
                failures.append("WING text value was assigned to the wrong node")
            }
            return values.map(\.text)
        }

        // Before a channel is selected nothing belongs to the control channel.
        if !texts([0xd7, 0x02, 0xdf, 0xde, 0xaf, 0x0e, 0x80] + Array("X".utf8)).isEmpty {
            failures.append("WING stream data without a channel was not ignored")
        }

        // A node hash with an escaped byte and a value split across chunks.
        let first = texts([0xdf, 0xd1, 0xd7, 0x02, 0xdf])
        let second = texts([0xde, 0xaf, 0x0e, 0x83, 0x4b])
        let third = texts(Array("ick".utf8))
        if !first.isEmpty || !second.isEmpty || third != ["Kick"] {
            failures.append("WING stream split across chunks was not decoded")
        }

        let otherChannel: [UInt8] = [0xdf, 0xd3, 0x80, 0x41, 0xdf, 0xd1]
        if !texts(otherChannel).isEmpty {
            failures.append("WING stream data of another channel was not ignored")
        }
        if texts([0xd0]) != [""] {
            failures.append("WING empty text value was not decoded")
        }
        if texts([0xd1, 0x01, 0x4f, 0x4b]) != ["OK"] {
            failures.append("WING long text value was not decoded")
        }
        if texts([0xd5, 0x00, 0x00, 0x00, 0x00, 0x01, 0x40, 0xde, 0x80, 0x5a]) != ["Z"] {
            failures.append("WING values without text were not skipped")
        }
    }

    private static func bytes(hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).compactMap { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)
        }
    }

    /// Hexadecimal examples are from "Unofficial X32/M32 OSC Remote Protocol".
    private static func testX32Protocol(_ failures: inout [String]) {
        if X32Protocol.infoRequest != Array("/info\0\0\0,\0\0\0".utf8) {
            failures.append("X32 info request differs from the protocol example")
        }
        if X32Protocol.meterRequest(page: 6) != Array("/meters\0,s\0\0/meters/6\0\0\0".utf8) {
            failures.append("X32 meter request is not padded as OSC requires")
        }
        if X32Protocol.read("/ch/01/config/name") != Array("/ch/01/config/name\0\0,\0\0\0".utf8) {
            failures.append("X32 parameter read must not carry a value")
        }

        let reply = bytes(hex: "2f6d65746572732f360000002c6200000000001404000000fd1d2137fdff7f3f0000803f6ebbd534")
        guard let meters = X32Message(packet: reply),
              case .blob(let blob)? = meters.arguments.first,
              let values = X32Protocol.meterValues(blob: blob) else {
            failures.append("X32 meter reply from the protocol example was not read")
            return
        }
        if X32Protocol.meterPage(address: meters.address) != 6 || values.count != 4 || values[2] != 1 {
            failures.append("X32 meter reply values were read incorrectly")
        }
        if X32Protocol.meterValues(blob: [5, 0, 0, 0, 0, 0, 0, 0]) != nil {
            failures.append("X32 meter blob with too few values was accepted")
        }
        if X32Protocol.meterPage(address: "/ch/01/config/name") != nil {
            failures.append("X32 parameter address was taken for a meter page")
        }

        let infoReply = "/info\0\0\0,ssss\0\0\0V2.05\0\0\0osc-server\0\0X32\0" + "2.12\0\0\0\0"
        let info = X32Message(packet: Array(infoReply.utf8))
        let expected: [X32Message.Argument] = [
            .string("V2.05"), .string("osc-server"), .string("X32"), .string("2.12")
        ]
        if info?.address != "/info" || info?.arguments != expected {
            failures.append("X32 info reply from the protocol example was not read")
        }

        let name = X32Message(packet: Array("/ch/01/config/name\0\0,s\0\0Kick\0\0\0\0".utf8))
        if name?.arguments != [X32Message.Argument.string("Kick")] {
            failures.append("X32 parameter reply was not read")
        }
        if X32Message(packet: [0x2f, 0x61]) != nil
            || X32Message(packet: Array("/a\0\0,b\0\0".utf8) + [0, 0, 0, 9, 1]) != nil {
            failures.append("A truncated X32 message was accepted")
        }
    }

    private static func testX32Definitions(_ failures: inout [String]) {
        let definitions = X32MixerDriver.definitions
        let pageSizes = [0: 70, 2: 49, 3: 22, 4: 82]
        for definition in definitions {
            guard let size = pageSizes[definition.page] else {
                failures.append("X32 section \(definition.descriptor.id) uses an unknown meter page")
                continue
            }
            let page = [Float](repeating: 1, count: size)
            if definition.levels(from: page) == nil {
                failures.append("X32 section \(definition.descriptor.id) exceeds its meter page")
            }
            if !definition.nameAddresses.isEmpty,
               definition.nameAddresses.count != definition.descriptor.stripCount {
                failures.append("X32 section \(definition.descriptor.id) has a wrong name count")
            }
        }
        let identifiers = definitions.map(\.descriptor.id)
        if Set(identifiers).count != identifiers.count {
            failures.append("X32 meter sections do not have unique identifiers")
        }
        guard let channels = definitions.first(where: { $0.descriptor.id == "ch" }),
              let main = definitions.first(where: { $0.descriptor.id == "main" }),
              let effects = definitions.first(where: { $0.descriptor.id == "fxrtn" }) else {
            failures.append("X32 channel, main or effect section is missing")
            return
        }
        if channels.descriptor.barsPerStrip != 1
            || main.descriptor.barsPerStrip != 2
            || effects.nameAddresses.last != "/fxrtn/07/config/name"
            || channels.nameAddresses.first != "/ch/01/config/name" {
            failures.append("X32 strip layout or name addresses changed")
        }

        var page = [Float](repeating: 0, count: 70)
        page[0] = 1
        page[1] = 8
        guard let levels = channels.levels(from: page), levels.count == 32 else {
            failures.append("X32 channel levels were not read")
            return
        }
        if levels[0] != 0 || abs(levels[1] - 18.06) > 0.01 || levels[2] != -Float.infinity {
            failures.append("X32 linear meter values were not converted to dB")
        }
        if channels.levels(from: [1, 2, 3]) != nil {
            failures.append("A short X32 meter page was accepted")
        }
    }

    private static func testX32Endpoint(_ failures: inout [String]) {
        let valid: [(text: String, host: String, port: UInt16)] = [
            ("192.168.1.20", "192.168.1.20", X32Protocol.port),
            (" x32.local ", "x32.local", X32Protocol.port),
            ("192.168.1.20:10023", "192.168.1.20", 10_023),
            ("x32.local:10024", "x32.local", 10_024),
            ("Mixer-1", "Mixer-1", X32Protocol.port),
            ("x32.example.com.", "x32.example.com", X32Protocol.port),
            ("X32_Rack", "X32_Rack", X32Protocol.port),
            ("X32_Rack:10023", "X32_Rack", 10_023)
        ]
        for expected in valid {
            let endpoint = X32Endpoint(parsing: expected.text)
            if endpoint?.host != expected.host || endpoint?.port != expected.port {
                failures.append("X32 address \(expected.text) was not read")
            }
            if !MixerKind.behringerX32.isValidAddress(expected.text) {
                failures.append("Valid X32 address \(expected.text) was rejected")
            }
        }

        let invalid = [
            "fe80::1", "[::1]:10023", "host:0", "host:70000", "host:abc", "host:",
            "a b", "", "x32..local", "-x32.local", "300.1.1.1", "192.168.1",
            ".", "..", "x32.local..", ".x32.local"
        ]
        for text in invalid {
            if X32Endpoint(parsing: text) != nil {
                failures.append("Invalid X32 address \(text) was accepted")
            }
            if !text.isEmpty, MixerKind.behringerX32.isValidAddress(text) {
                failures.append("Invalid X32 address \(text) was offered to the driver")
            }
        }
        if !MixerKind.behringerX32.isValidAddress(nil)
            || !MixerKind.behringerX32.isValidAddress("  ") {
            failures.append("An empty X32 address must mean automatic discovery")
        }
        if !MixerKind.behringerWing.isValidAddress("fe80::1")
            || !MixerKind.none.isValidAddress("a b") {
            failures.append("Address validation must apply to X32 only")
        }
    }

    private static func testX32Client(_ failures: inout [String]) {
        let console = in_addr(s_addr: 0x1401_a8c0)
        let other = in_addr(s_addr: 0x1501_a8c0)
        if !X32Client.acceptsInfo(from: console, expected: console)
            || X32Client.acceptsInfo(from: other, expected: console) {
            failures.append("X32 info reply was accepted from another address than configured")
        }
        if !X32Client.acceptsInfo(from: other, expected: nil) {
            failures.append("X32 discovery did not accept the first info reply")
        }
        // 255.255.255.255 and 192.168.1.255 (network byte order in s_addr).
        let limitedBroadcast = in_addr(s_addr: 0xffff_ffff)
        let subnetBroadcast = in_addr(s_addr: 0xff01_a8c0)
        if !X32Client.acceptsInfo(from: other, expected: limitedBroadcast)
            || !X32Client.acceptsInfo(from: other, expected: subnetBroadcast) {
            failures.append("X32 broadcast destination did not accept the console's reply")
        }
    }

    private static func testX32StaleLevels(_ failures: inout [String]) {
        let definitions = X32MixerDriver.definitions.filter { ["ch", "main"].contains($0.descriptor.id) }
        let pages: [Int: [Float]] = [
            0: [Float](repeating: 1, count: 70),
            2: [Float](repeating: 1, count: 49)
        ]
        let staleAfter = MixerConnectionController.Timing().staleLevelsAfter

        let partly = X32MixerDriver.levels(
            for: definitions,
            pages: pages,
            ages: [0: 0.05, 2: staleAfter],
            staleAfter: staleAfter
        )
        if partly["ch"]?.count != 32 || partly["main"] != nil {
            failures.append("Levels of a stale X32 meter page stayed on the display")
        }
        let fresh = X32MixerDriver.levels(
            for: definitions,
            pages: pages,
            ages: [0: 0.05, 2: staleAfter / 2],
            staleAfter: staleAfter
        )
        if fresh["ch"]?.count != 32 || fresh["main"]?.count != 2 {
            failures.append("Levels of fresh X32 meter pages were not shown")
        }
        let withoutAge = X32MixerDriver.levels(
            for: definitions,
            pages: pages,
            ages: [0: 0.05],
            staleAfter: staleAfter
        )
        if withoutAge["main"] != nil {
            failures.append("X32 levels without a reception time were shown")
        }
    }

    private static func section(_ id: String, strips: Int, bars: Int) -> MixerBridgeSection {
        MixerBridgeSection(
            id: id,
            shortTitle: id,
            strips: (0..<strips).map { MixerBridgeStrip(number: $0 + 1, name: "", barCount: bars) }
        )
    }

    private static func testLayout(_ failures: inout [String]) {
        let size = CGSize(width: 1_920, height: 480)
        let usual = [
            section("ch", strips: 40, bars: 2),
            section("aux", strips: 8, bars: 2),
            section("bus", strips: 16, bars: 2),
            section("main", strips: 4, bars: 2),
            section("mtx", strips: 8, bars: 2),
            section("dca", strips: 8, bars: 2),
            section("in", strips: 24, bars: 1),
            section("out", strips: 8, bars: 1)
        ]
        let oneRow = MixerBridgeLayout.compute(sections: usual, size: size)
        if oneRow.rowCount != 1 || oneRow.sections.count != usual.count {
            failures.append("Usual meter bridge sections should fit one row at 1920 pixels")
        }

        let crowded = usual + (0..<4).map { section("io\($0)", strips: 48, bars: 1) }
        let twoRows = MixerBridgeLayout.compute(sections: crowded, size: size)
        if twoRows.rowCount != 2 || twoRows.sections.count != crowded.count {
            failures.append("Crowded meter bridge did not wrap into two rows")
        }

        // Far more sections than fit: rows are limited by the height, then gaps
        // and bars shrink. The last size cannot hold the bars at their smallest
        // pitch even without gaps.
        let many = (0..<30).map { section("s\($0)", strips: 16, bars: 1) }
        var checked = [(layout: oneRow, size: size), (layout: twoRows, size: size)]
        for smallSize in [
            CGSize(width: 600, height: 200),
            CGSize(width: 300, height: 60),
            CGSize(width: 200, height: 60)
        ] {
            let layout = MixerBridgeLayout.compute(sections: many, size: smallSize)
            if layout.sections.map(\.id) != many.map(\.id) {
                failures.append("Not every meter bridge section was placed at \(smallSize)")
            }
            if layout.rowCount < 1 || (smallSize.height <= 60 && layout.rowCount != 1) {
                failures.append("Meter bridge used rows the height cannot hold at \(smallSize)")
            }
            checked.append((layout: layout, size: smallSize))
        }

        for (layout, area) in checked {
            for placed in layout.sections {
                let outside = placed.bars.contains {
                    $0.frame.minX < 0 || $0.frame.minY < 0
                        || $0.frame.maxX > area.width || $0.frame.maxY > area.height
                        || $0.frame.width <= 0
                }
                if outside {
                    failures.append("Meter bridge section \(placed.id) left the display at \(area)")
                }
            }
            for (index, first) in layout.sections.enumerated() {
                for second in layout.sections[(index + 1)...] {
                    // Sections squeezed without gaps may touch, but not overlap.
                    let overlap = first.frame.intersection(second.frame)
                    if !overlap.isNull, overlap.width > 0.001, overlap.height > 0.001 {
                        failures.append("Meter bridge sections \(first.id) and \(second.id) overlap")
                    }
                }
            }
        }

        let stereo = MixerBridgeLayout.compute(
            sections: [section("ch", strips: 2, bars: 2)],
            size: size
        )
        if stereo.sections.first?.bars.map(\.levelIndex) != [0, 1, 2, 3] {
            failures.append("Stereo strips did not map to consecutive level values")
        }
        let empty = MixerBridgeLayout.compute(sections: [section("in", strips: 0, bars: 1)], size: size)
        if !empty.sections.isEmpty {
            failures.append("A section without known strips should not be shown")
        }
    }

    private static func testSettings(_ failures: inout [String]) {
        var settings = PersistedSettings()
        if settings.mixer.kind != .none || !settings.mixer.visibleSections.isEmpty {
            failures.append("No mixer should be configured by default")
        }
        settings.mixer.kind = .behringerWing
        settings.mixer.address = " 192.168.1.20 "
        for section in settings.mixer.kind.sections where ["dca", "in.A"].contains(section.id) {
            settings.mixer.setVisible(section, section.id == "in.A")
        }
        do {
            let data = try PropertyListEncoder().encode(settings)
            let decoded = try PropertyListDecoder().decode(PersistedSettings.self, from: data)
            if decoded.mixer != settings.mixer {
                failures.append("Mixer settings did not survive encoding")
            }
            let visible = decoded.mixer.visibleSections.map(\.id)
            if visible.contains("dca") || !visible.contains("in.A") || !visible.contains("ch") {
                failures.append("Mixer section visibility was not applied")
            }
            if decoded.mixer.connectionAddress != "192.168.1.20" {
                failures.append("Mixer address was not trimmed")
            }

            guard var root = try PropertyListSerialization.propertyList(
                from: data,
                format: nil
            ) as? [String: Any], var mixer = root["mixer"] as? [String: Any] else {
                failures.append("Mixer settings test could not inspect the property list")
                return
            }
            mixer["kind"] = "consoleFromNewerVersion"
            root["mixer"] = mixer
            let changed = try PropertyListSerialization.data(
                fromPropertyList: root,
                format: .binary,
                options: 0
            )
            let unknown = try PropertyListDecoder().decode(PersistedSettings.self, from: changed)
            if unknown.mixer.kind != .none || unknown.mixer.address != settings.mixer.address {
                failures.append("Unknown mixer type was not handled independently")
            }

            root.removeValue(forKey: "mixer")
            let older = try PropertyListSerialization.data(
                fromPropertyList: root,
                format: .binary,
                options: 0
            )
            let upgraded = try PropertyListDecoder().decode(PersistedSettings.self, from: older)
            if upgraded.mixer != MixerSettings() {
                failures.append("Settings from before mixer support did not use defaults")
            }
        } catch {
            failures.append("Mixer settings failed to encode or decode: \(error)")
        }

        if AnalysisDisplayMode.meterBridge.usesAudioAnalysis
            || AnalysisDisplayMode.none.usesAudioAnalysis
            || !AnalysisDisplayMode.spectrogram.usesAudioAnalysis
            || !AnalysisDisplayMode.transferFunction.usesAudioAnalysis
            || !AnalysisDisplayMode.combined.usesAudioAnalysis {
            failures.append("Meter bridge must not run the audio analysis")
        }
    }

    private static func testSectionVisibilityByKind(_ failures: inout [String]) {
        var settings = MixerSettings()
        settings.kind = .behringerWing
        guard let wingChannels = MixerKind.behringerWing.sections.first(where: { $0.id == "ch" }),
              let x32Channels = MixerKind.behringerX32.sections.first(where: { $0.id == "ch" }) else {
            failures.append("WING or X32 channel section is missing")
            return
        }
        settings.setVisible(wingChannels, false)
        settings.kind = .behringerX32
        if !settings.isVisible(x32Channels) || !settings.visibleSections.contains(where: { $0.id == "ch" }) {
            failures.append("Hiding WING channels also hid X32 channels")
        }
        settings.kind = .behringerWing
        if settings.isVisible(wingChannels) {
            failures.append("WING section choice was lost after switching the console type")
        }

        do {
            let data = try PropertyListEncoder().encode(settings)
            let decoded = try PropertyListDecoder().decode(MixerSettings.self, from: data)
            if decoded != settings || decoded.isVisible(wingChannels) {
                failures.append("Section choices by console type did not survive encoding")
            }
            guard let stored = try PropertyListSerialization.propertyList(
                from: data,
                format: nil
            ) as? [String: Any] else {
                failures.append("Mixer section test could not inspect the property list")
                return
            }
            if stored["sectionVisibility"] as? [String: Bool] != ["ch": false] {
                failures.append("Section choices of the current console were not kept for older versions")
            }
            let byKind = stored["sectionVisibilityByKind"] as? [String: [String: Bool]]
            if byKind?[MixerKind.behringerWing.rawValue] != ["ch": false] {
                failures.append("Section choices were not stored by console type")
            }

            let older: [String: Any] = [
                "kind": MixerKind.behringerX32.rawValue,
                "address": "",
                "sectionVisibility": ["ch": false, "auxout": true]
            ]
            let olderData = try PropertyListSerialization.data(
                fromPropertyList: older,
                format: .binary,
                options: 0
            )
            var migrated = try PropertyListDecoder().decode(MixerSettings.self, from: olderData)
            let visible = migrated.visibleSections.map(\.id)
            if visible.contains("ch") || !visible.contains("auxout") {
                failures.append("Section choices of an older version were not kept")
            }
            migrated.kind = .behringerWing
            if !migrated.isVisible(wingChannels) {
                failures.append("Section choices of an older version applied to another console type")
            }
        } catch {
            failures.append("Mixer section choices failed to encode or decode: \(error)")
        }
    }

    private static func testUnknownDisplayMode(_ failures: inout [String]) {
        var settings = PersistedSettings()
        settings.spectrogram.displayMode = .combined
        settings.spectrogram.palette = .rgb
        settings.spectrogram.frequencyRange = .voice
        do {
            let data = try PropertyListEncoder().encode(settings)
            guard var root = try PropertyListSerialization.propertyList(
                from: data,
                format: nil
            ) as? [String: Any], var spectrogram = root["spectrogram"] as? [String: Any] else {
                failures.append("Display mode test could not inspect the property list")
                return
            }
            spectrogram["displayMode"] = "fromNewerVersion"
            spectrogram["isEnabled"] = true
            spectrogram["isTransferFunctionEnabled"] = false
            root["spectrogram"] = spectrogram
            let changed = try PropertyListSerialization.data(
                fromPropertyList: root,
                format: .binary,
                options: 0
            )
            let decoded = try PropertyListDecoder().decode(PersistedSettings.self, from: changed)
            if decoded.spectrogram.displayMode != .spectrogram
                || decoded.spectrogram.palette != .rgb
                || decoded.spectrogram.frequencyRange != .voice {
                failures.append("An unknown display mode reset the analysis settings")
            }
        } catch {
            failures.append("Display mode test failed to encode or decode: \(error)")
        }
    }

    private static func testConnection(_ failures: inout [String]) {
        var drivers: [FakeDriver] = []
        let timing = MixerConnectionController.Timing()
        let controller = MixerConnectionController(timing: timing) { kind in
            guard kind != .none else { return nil }
            let driver = FakeDriver()
            drivers.append(driver)
            return driver
        }
        let identity = MixerIdentity(address: "10.0.0.2", name: "WING", model: "wing", firmware: "3")

        controller.configure(MixerSettings(), now: 0)
        controller.tick(now: 100)
        if controller.phase != .disabled || !drivers.isEmpty {
            failures.append("An unconfigured mixer must not start a connection")
        }

        var settings = MixerSettings()
        settings.kind = .behringerWing
        controller.configure(settings, now: 0)
        if controller.phase != .connecting || drivers.count != 1 {
            failures.append("A configured mixer did not connect on its own")
        }
        if drivers.last?.startedAddress != .some(nil) {
            failures.append("An empty address must use automatic discovery")
        }

        guard let first = drivers.last else { return }
        controller.tick(now: timing.attemptTimeout)
        if controller.phase != .waitingToRetry || first.stopCount != 1 {
            failures.append("A connection attempt without a result did not time out")
        }
        controller.tick(now: timing.attemptTimeout + timing.retryDelay - 0.1)
        if drivers.count != 1 {
            failures.append("The connection was retried before the retry delay")
        }
        var now = timing.attemptTimeout + timing.retryDelay
        controller.tick(now: now)
        if controller.phase != .connecting || drivers.count != 2 {
            failures.append("An unavailable mixer was not retried")
        }

        guard let second = drivers.last else { return }
        second.update = MixerDriverUpdate(
            state: .connected(identity),
            secondsSinceMeterData: 0.02,
            levels: ["in.LCL": [-20, -10]],
            stripCounts: ["in.LCL": 2],
            names: ["ch": [0: "Kick"]]
        )
        controller.tick(now: now)
        if controller.phase != .connected(identity) || controller.levels["in.LCL"] != [-20, -10] {
            failures.append("A connected mixer did not deliver its levels")
        }
        let local = controller.sections.first { $0.id == "in.LCL" }
        if local?.strips.count != 2 || local?.strips.first?.barCount != 1 {
            failures.append("The connector count reported by the console was not applied")
        }
        if controller.sections.first(where: { $0.id == "ch" })?.strips.first?.name != "Kick" {
            failures.append("A strip name reported by the console was not applied")
        }

        second.update.secondsSinceMeterData = timing.staleLevelsAfter
        controller.tick(now: now)
        if !controller.levels.isEmpty || !controller.phase.isConnected {
            failures.append("Stale levels stayed on the display")
        }
        second.update.secondsSinceMeterData = timing.meterDataTimeout
        controller.tick(now: now)
        if controller.phase != .waitingToRetry || second.stopCount != 1 {
            failures.append("A console that stopped sending meters was not reconnected")
        }

        now += timing.retryDelay
        controller.tick(now: now)
        guard let third = drivers.last, third !== second else {
            failures.append("The connection was not retried after losing the console")
            return
        }
        third.update = MixerDriverUpdate(state: .failed)
        controller.tick(now: now)
        if controller.phase != .waitingToRetry {
            failures.append("A failed driver did not schedule a retry")
        }
        if controller.sections.first(where: { $0.id == "ch" })?.strips.first?.name != "Kick" {
            failures.append("Strip names were lost while reconnecting")
        }

        settings.address = "10.0.0.9"
        controller.configure(settings, now: now)
        if drivers.last?.startedAddress != .some("10.0.0.9") {
            failures.append("A changed address did not restart the connection")
        }
        settings.kind = .none
        controller.configure(settings, now: now)
        if controller.phase != .disabled || drivers.last?.stopCount != 1 {
            failures.append("Removing the mixer did not end the connection")
        }
    }

    private static func testConnectionWithoutAttempt(_ failures: inout [String]) {
        var drivers: [FakeDriver] = []
        let timing = MixerConnectionController.Timing()
        let controller = MixerConnectionController(timing: timing) { kind in
            guard kind != .none else { return nil }
            let driver = FakeDriver()
            drivers.append(driver)
            return driver
        }

        var settings = MixerSettings()
        settings.kind = .behringerX32
        settings.address = "fe80::1"
        controller.configure(settings, now: 0)
        controller.tick(now: timing.attemptTimeout + timing.retryDelay)
        controller.tick(now: 2 * (timing.attemptTimeout + timing.retryDelay))
        if controller.phase != .invalidAddress || controller.phase.isActive || !drivers.isEmpty {
            failures.append("An invalid X32 address started or retried a connection")
        }
        controller.configure(settings, now: 60)
        if controller.phase != .invalidAddress || !drivers.isEmpty {
            failures.append("Unchanged invalid X32 address left its state")
        }

        settings.address = "x32.local:10023"
        controller.configure(settings, now: 60)
        if controller.phase != .connecting || drivers.count != 1
            || drivers.last?.startedAddress != .some("x32.local:10023") {
            failures.append("A corrected X32 address did not connect")
        }

        for section in settings.kind.sections {
            settings.setVisible(section, false)
        }
        controller.configure(settings, now: 61)
        controller.tick(now: 200)
        if controller.phase != .noSectionsSelected || controller.phase.isActive
            || drivers.count != 1 || drivers.last?.stopCount != 1 {
            failures.append("A mixer without sections kept a connection")
        }

        settings.address = "a b"
        controller.configure(settings, now: 201)
        if controller.phase != .noSectionsSelected || drivers.count != 1 {
            failures.append("A mixer without sections must not report its address")
        }

        let active: [MixerConnectionController.Phase] = [.connecting, .waitingToRetry]
        if !active.allSatisfy(\.isActive) || MixerConnectionController.Phase.disabled.isActive {
            failures.append("Mixer phases needing regular ticks are wrong")
        }
    }
}
