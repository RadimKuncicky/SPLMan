import CoreGraphics
import Foundation
import WingKit
import X32Kit

enum MixerTests {
    private final class FakeDriver: MixerDriver {
        var update = MixerDriverUpdate(state: .connecting)
        var startedAddress: String??
        var startedTarget: PreferredMixer??
        var startedSections: [MixerMeterSectionDescriptor] = []
        var startedIncludeRTA: Bool?
        var stopCount = 0

        func start(
            address: String?,
            target: PreferredMixer?,
            sections: [MixerMeterSectionDescriptor],
            includeRTA: Bool
        ) {
            startedAddress = .some(address)
            startedTarget = .some(target)
            startedSections = sections
            startedIncludeRTA = includeRTA
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
        testWingFilter(&failures)
        testWingMeasurement(&failures)
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
        testPreferredMatching(&failures)
        testPreferredSettings(&failures)
        testScanList(&failures)
        testConnectionTarget(&failures)
        testConsoleSwitchClearsNames(&failures)
        testWingDiscoveryTarget(&failures)
        testX32ConsoleInfo(&failures)
        testX32RTADecoding(&failures)
        testX32RTAStaleness(&failures)
        testX32RTASettings(&failures)
        testWingRTARequest(&failures)
        testWingRTAMeasurement(&failures)
        testWingStreamIntegers(&failures)
        testWingRTASettings(&failures)
        testRTARequestsAreReadOnly(&failures)
        testRTAConnection(&failures)
        testRTAMissingRetry(&failures)
        testRTALiveness(&failures)
        testRTADisplayMode(&failures)
        testRTALayout(&failures)
        testRTAText(&failures)
        testPeakHold(&failures)
        return failures
    }

    private static func testPeakHold(_ failures: inout [String]) {
        var hold = MixerPeakHold()
        func peak(_ result: [String: [Float]]) -> Float? { result["a"]?.first }
        if peak(hold.update(["a": [-10]], now: 100)) != -10 {
            failures.append("Peak hold must start at the current level")
        }
        if peak(hold.update(["a": [-30]], now: 102.9)) != -10 {
            failures.append("Peak hold must keep the peak for 3 seconds")
        }
        if peak(hold.update(["a": [-20]], now: 103)) != -20 {
            failures.append("Peak hold must fall to the current level after 3 seconds")
        }
        if peak(hold.update(["a": [-5]], now: 103.1)) != -5 {
            failures.append("A higher level must replace the held peak immediately")
        }
        if peak(hold.update(["a": [-40]], now: 105)) != -5 {
            failures.append("A new peak must be held for 3 seconds from its own time")
        }
        if hold.update(["b": [0]], now: 105.1)["a"] != nil {
            failures.append("Peak hold kept a section that disappeared")
        }
        if peak(hold.update(["a": [-50]], now: 105.2)) != -50 {
            failures.append("A returning section must not inherit an old peak")
        }
        hold.reset()
        if peak(hold.update(["a": [-50]], now: 105.3)) != -50 {
            failures.append("Peak hold reset did not clear the peaks")
        }
        let scale = MixerMeterScale.self
        if scale.zone(levelDB: -18) != .green || scale.zone(levelDB: -17.9) != .yellow
            || scale.zone(levelDB: -0.1) != .yellow || scale.zone(levelDB: 0) != .red {
            failures.append("Mixer meter zone does not match its segments")
        }
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
            || WingConsoleInfo(discoveryReply: "WING,1") != nil
            || WingConsoleInfo(discoveryReply: "WING,,Stage,wing,S1,3") != nil {
            failures.append("An invalid WING discovery reply was accepted")
        }
        let comma = WingConsoleInfo(discoveryReply: "WING,10.0.0.5,FOH, main,wing-rack,S1,3.1")
        if comma?.ip != "10.0.0.5" || comma?.name != "FOH, main" || comma?.model != "wing-rack"
            || comma?.serial != "S1" || comma?.firmware != "3.1" {
            failures.append("A WING console name with a comma shifted the other fields")
        }

        let report = WingMeterReport(packet: [0, 0, 0, 2, 0xff, 0x00, 0x01, 0x00, 0x07])
        if report?.reportID != 2 || report?.words != [-256, 256] {
            failures.append("WING meter report was not read as big-endian values")
        }
        if WingMeterReport(packet: [0, 0, 2]) != nil {
            failures.append("A truncated WING meter report was accepted")
        }
    }

    private static func testWingFilter(_ failures: inout [String]) {
        let filter = WingConsoleFilter(address: "10.0.0.5")
        if !filter.acceptsMeters(from: "10.0.0.5") || filter.acceptsMeters(from: "10.0.0.6") {
            failures.append("WING meters were not limited to the console's address")
        }
        if filter.acceptsMeters(from: "not an address") || filter.acceptsMeters(from: "") {
            failures.append("WING meters from an unreadable sender were accepted")
        }
        if !WingConsoleFilter(address: " 10.0.0.5 ").acceptsMeters(from: "10.0.0.5") {
            failures.append("WING console address was not compared as IPv4")
        }
        if !WingConsoleFilter(address: nil).acceptsMeters(from: "10.0.0.6")
            || !WingConsoleFilter(address: "wing.local").acceptsMeters(from: "10.0.0.6") {
            failures.append("WING meters were dropped while the console's address was unknown")
        }

        guard let own = WingConsoleInfo(discoveryReply: "WING,10.0.0.5,FOH,wing-rack,S1,3.1"),
              let other = WingConsoleInfo(discoveryReply: "WING,10.0.0.7,MON,wing,S2,3.1"),
              let unreadable = WingConsoleInfo(discoveryReply: "WING,console,X,wing,S3,3.1") else {
            failures.append("WING filter test replies were not read")
            return
        }
        if filter.acceptsConsoleInfo(other, from: "10.0.0.7")
            || filter.acceptsConsoleInfo(unreadable, from: "console") {
            failures.append("Another WING console's discovery reply replaced the console")
        }
        if !filter.acceptsConsoleInfo(own, from: "10.0.0.7")
            || !filter.acceptsConsoleInfo(other, from: "10.0.0.5") {
            failures.append("The WING console's own discovery reply was rejected")
        }
        if !WingConsoleFilter(address: nil).acceptsConsoleInfo(other, from: "10.0.0.7") {
            failures.append("A WING discovery reply was rejected before the address was known")
        }
    }

    private static func testWingMeasurement(_ failures: inout [String]) {
        typealias Measurement = WingGroupMeasurement
        let ch0 = WingMeter(kind: .channel, index: 0)
        let ch1 = WingMeter(kind: .channel, index: 1)
        let aux = WingMeter(kind: .aux, index: 0)
        let source = WingMeter(kind: .source, index: 0)
        let output = WingMeter(kind: .output, index: 0)
        func required(_ meters: [WingMeter]) -> WingMeterGroup {
            WingMeterGroup(meters: meters, isRequired: true)
        }
        func optional(_ meters: [WingMeter]) -> WingMeterGroup {
            WingMeterGroup(meters: meters, isRequired: false)
        }

        // Collections grow; reports of the previous one are not longer than the total.
        var normal = Measurement(groups: [required([ch0, ch1]), optional([source]), required([aux])])
        if normal.start() != .request([ch0, ch1])
            || normal.receive(length: 0) != nil
            || normal.receive(length: 16) != .request([ch0, ch1, source])
            || normal.receive(length: 16) != nil
            || normal.receive(length: 18) != .request([ch0, ch1, source, aux])
            || normal.receive(length: 18) != nil
            || normal.receive(length: 26) != .finished(lengths: [16, 2, 8]) {
            failures.append("WING group lengths were not measured cumulatively")
        }

        var absent = Measurement(groups: [required([ch0]), optional([source]), optional([output])])
        if absent.start() != .request([ch0])
            || absent.receive(length: 8) != .request([ch0, source])
            || absent.receive(length: 8) != nil
            || absent.timeout() != .request([ch0, output])
            || absent.receive(length: 9) != .finished(lengths: [8, 0, 1]) {
            failures.append("An absent optional WING group was not skipped")
        }

        var retried = Measurement(groups: [required([ch0]), required([aux])])
        if retried.start() != .request([ch0])
            || retried.receive(length: 8) != .request([ch0, aux])
            || retried.receive(length: 8) != nil
            || retried.timeout() != .request([ch0, aux])
            || retried.receive(length: 16) != .finished(lengths: [8, 8]) {
            failures.append("A late required WING group was not requested again")
        }

        var silent = Measurement(groups: [required([ch0])])
        let silentSteps = [silent.start(), silent.timeout(), silent.timeout()]
        let repeated = [Measurement.Step](repeating: .request([ch0]), count: Measurement.maximumAttempts)
        if silentSteps != repeated {
            failures.append("A silent required WING group was not requested again")
        }
        if case .failed = silent.timeout() {} else {
            failures.append("A silent required WING group did not end the session")
        }

        var missing = Measurement(groups: [optional([source]), required([ch0])])
        if missing.start() != .request([source])
            || missing.timeout() != .request([source])
            || missing.timeout() != .request([source])
            || missing.timeout() != .request([ch0])
            || missing.receive(length: 8) != .finished(lengths: [0, 8]) {
            failures.append("A silent optional WING group was not given up")
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
        if texts([0xd5, 0x00, 0x00, 0x00, 0x00, 0x01, 0xd3, 0x80, 0x41, 0xde, 0x80, 0x5a]) != ["Z"] {
            failures.append("WING values without text were not skipped")
        }

        // Navigation without a hash leads to a node the parser cannot name.
        let hash: [UInt8] = [0xd7, 0x02, 0xdf, 0xde, 0xaf, 0x0e]
        let navigations: [[UInt8]] = [[0x40], [0x7f], [0xd2, 0x80, 0x43], [0xda], [0xdb]]
        for navigation in navigations {
            if !texts(navigation + [0x80, 0x41]).isEmpty {
                failures.append("WING text after navigation \(navigation) was given the last hashed node")
            }
            if texts(hash + [0x80, 0x42]) != ["B"] {
                failures.append("WING text after a new node hash was not reported")
            }
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

    private static func testPreferredMatching(_ failures: inout [String]) {
        let wing = PreferredMixer(
            kind: .behringerWing,
            name: "FOH",
            model: "wing-rack",
            serial: "S1",
            address: "10.0.0.5"
        )
        if !wing.matches(kind: .behringerWing, name: "Renamed", model: "wing", serial: " s1 ", address: "10.0.0.9") {
            failures.append("A WING with the selected serial number was not recognized")
        }
        if wing.matches(kind: .behringerWing, name: "FOH", model: "wing-rack", serial: "S2", address: "10.0.0.5") {
            failures.append("Another WING with the same name and address was taken for the selected one")
        }

        let wingWithoutSerial = PreferredMixer(kind: .behringerWing, name: "FOH", model: "wing-rack")
        if !wingWithoutSerial.matches(kind: .behringerWing, name: "FOH", model: "wing-rack", serial: "S9", address: "10.0.0.7")
            || wingWithoutSerial.matches(kind: .behringerWing, name: "MON", model: "wing-rack", serial: "S9", address: "10.0.0.7")
            || wingWithoutSerial.matches(kind: .behringerWing, name: "FOH", model: "wing-compact", serial: "S9", address: "10.0.0.7") {
            failures.append("A WING without a serial number was not recognized by name and model")
        }

        let x32 = PreferredMixer(kind: .behringerX32, name: "X32-FOH", model: "X32", address: "10.0.0.20")
        if !x32.matches(kind: .behringerX32, name: "X32-FOH", model: "X32", serial: "", address: "10.0.0.33") {
            failures.append("An X32 with the selected name and model was not recognized at another address")
        }
        if x32.matches(kind: .behringerX32, name: "X32-MON", model: "X32", serial: "", address: "10.0.0.20")
            || x32.matches(kind: .behringerX32, name: "X32-FOH", model: "M32", serial: "", address: "10.0.0.20") {
            failures.append("Another X32 at the selected address was taken for the selected one")
        }

        let x32WithoutName = PreferredMixer(kind: .behringerX32, model: "X32", address: "10.0.0.20")
        if !x32WithoutName.matches(kind: .behringerX32, name: "", model: "X32", serial: "", address: " 10.0.0.20 ")
            || x32WithoutName.matches(kind: .behringerX32, name: "", model: "X32", serial: "", address: "10.0.0.21") {
            failures.append("An X32 without a network name was not recognized by its address")
        }
        if PreferredMixer(kind: .behringerX32).matches(
            kind: .behringerX32,
            name: "",
            model: "",
            serial: "",
            address: ""
        ) {
            failures.append("A selection without anything to compare matched a console")
        }

        if wing.matches(kind: .behringerX32, name: "FOH", model: "wing-rack", serial: "S1", address: "10.0.0.5")
            || x32.matches(kind: .behringerWing, name: "X32-FOH", model: "X32", serial: "", address: "10.0.0.20") {
            failures.append("A console of another type was taken for the selected one")
        }
        let found = DiscoveredMixer(
            kind: .behringerWing,
            address: "10.0.0.9",
            name: "Other",
            model: "wing",
            serial: "S1",
            firmware: "3.1"
        )
        let selected = PreferredMixer(
            kind: .behringerWing,
            name: "Other",
            model: "wing",
            serial: "S1",
            address: "10.0.0.9"
        )
        if !wing.matches(found) || PreferredMixer(found) != selected {
            failures.append("A console found on the network was not selected correctly")
        }
    }

    private static func testPreferredSettings(_ failures: inout [String]) {
        var settings = MixerSettings()
        settings.kind = .behringerWing
        settings.preferredConsole = PreferredMixer(
            kind: .behringerWing,
            name: "FOH",
            model: "wing-rack",
            serial: "S1",
            address: "10.0.0.5"
        )
        if settings.connectionTarget != settings.preferredConsole {
            failures.append("The selected console was not used for discovery")
        }
        do {
            let data = try PropertyListEncoder().encode(settings)
            let decoded = try PropertyListDecoder().decode(MixerSettings.self, from: data)
            if decoded != settings {
                failures.append("The selected console did not survive encoding")
            }

            let older: [String: Any] = ["kind": MixerKind.behringerWing.rawValue, "address": ""]
            let olderData = try PropertyListSerialization.data(
                fromPropertyList: older,
                format: .binary,
                options: 0
            )
            let upgraded = try PropertyListDecoder().decode(MixerSettings.self, from: olderData)
            if upgraded.preferredConsole != nil || upgraded.kind != .behringerWing {
                failures.append("Settings from before console selection were not read")
            }

            guard var stored = try PropertyListSerialization.propertyList(
                from: data,
                format: nil
            ) as? [String: Any], var preferred = stored["preferredConsole"] as? [String: Any] else {
                failures.append("Console selection test could not inspect the property list")
                return
            }
            preferred["kind"] = "consoleFromNewerVersion"
            stored["preferredConsole"] = preferred
            let unknownData = try PropertyListSerialization.data(
                fromPropertyList: stored,
                format: .binary,
                options: 0
            )
            let unknown = try PropertyListDecoder().decode(MixerSettings.self, from: unknownData)
            if unknown.preferredConsole != nil || unknown.kind != .behringerWing
                || unknown.address != settings.address {
                failures.append("An unknown selected console type was not dropped on its own")
            }

            preferred["kind"] = MixerKind.behringerX32.rawValue
            preferred.removeValue(forKey: "serial")
            stored["preferredConsole"] = preferred
            let otherKindData = try PropertyListSerialization.data(
                fromPropertyList: stored,
                format: .binary,
                options: 0
            )
            let otherKind = try PropertyListDecoder().decode(MixerSettings.self, from: otherKindData)
            if otherKind.preferredConsole != nil {
                failures.append("A selected console of another type than the console type was kept")
            }

            stored["kind"] = MixerKind.behringerX32.rawValue
            let missingSerialData = try PropertyListSerialization.data(
                fromPropertyList: stored,
                format: .binary,
                options: 0
            )
            let missingSerial = try PropertyListDecoder().decode(MixerSettings.self, from: missingSerialData)
            if missingSerial.preferredConsole?.serial != ""
                || missingSerial.preferredConsole?.name != "FOH" {
                failures.append("A selected console without a serial number was not read")
            }
        } catch {
            failures.append("Console selection failed to encode or decode: \(error)")
        }

        settings.address = "10.0.0.9"
        if settings.connectionTarget != nil {
            failures.append("An entered address did not take precedence over the selected console")
        }
        settings.address = ""
        settings.kind = .behringerX32
        if settings.connectionTarget != nil {
            failures.append("A selected console of another type was used for discovery")
        }
    }

    private static func testScanList(_ failures: inout [String]) {
        func console(
            _ kind: MixerKind,
            _ address: String,
            name: String,
            serial: String = ""
        ) -> DiscoveredMixer {
            DiscoveredMixer(kind: kind, address: address, name: name, model: "m", serial: serial, firmware: "1")
        }
        var list = MixerScanList()
        list.record(console(.behringerWing, "10.0.0.5", name: "FOH", serial: "S1"), now: 0)
        list.record(console(.behringerWing, "10.0.0.6", name: "FOH", serial: "S1"), now: 1)
        list.record(console(.behringerX32, "10.0.0.20", name: "X32-MON"), now: 2)
        list.record(console(.behringerX32, "10.0.0.20", name: "X32-MON"), now: 3)
        list.record(console(.behringerX32, "10.0.0.21", name: "X32-MON"), now: 3)
        let found = list.consoles
        if found.count != 3 || found.filter({ $0.kind == .behringerWing }).count != 1 {
            failures.append("Repeated scan replies were not merged per console")
        }
        if found.first?.kind != .behringerWing || found.first?.address != "10.0.0.6" {
            failures.append("A WING that changed its address was not updated")
        }

        list.prune(now: 1 + MixerScanList.lifetime - 0.1)
        if list.consoles.count != 3 {
            failures.append("A console that answered lately was dropped")
        }
        list.prune(now: 1 + MixerScanList.lifetime)
        if list.consoles.map(\.address) != ["10.0.0.20", "10.0.0.21"] {
            failures.append("A console that stopped answering was not dropped")
        }
        list.prune(now: 3 + MixerScanList.lifetime)
        if !list.consoles.isEmpty {
            failures.append("Consoles that stopped answering stayed in the list")
        }

        for index in 0..<(MixerScanList.maximumConsoles + 5) {
            list.record(console(.behringerX32, "10.1.0.\(index)", name: "X"), now: 100)
        }
        if list.consoles.count != MixerScanList.maximumConsoles {
            failures.append("The list of found consoles was not limited")
        }
    }

    private static func testConnectionTarget(_ failures: inout [String]) {
        var drivers: [FakeDriver] = []
        let timing = MixerConnectionController.Timing()
        let controller = MixerConnectionController(timing: timing) { kind in
            guard kind != .none else { return nil }
            let driver = FakeDriver()
            drivers.append(driver)
            return driver
        }
        let target = PreferredMixer(kind: .behringerX32, name: "X32-FOH", model: "X32", address: "10.0.0.20")
        var settings = MixerSettings()
        settings.kind = .behringerX32
        settings.preferredConsole = target

        controller.configure(settings, now: 0)
        if drivers.last?.startedAddress != .some(nil) || drivers.last?.startedTarget != .some(target) {
            failures.append("Discovery was not limited to the selected console")
        }
        drivers.last?.update = MixerDriverUpdate(state: .failed)
        controller.tick(now: 1)
        controller.tick(now: 1 + timing.retryDelay)
        if controller.phase != .connecting || drivers.count != 2
            || drivers.last?.startedTarget != .some(target) {
            failures.append("A selected console that was not found was not searched for again")
        }

        settings.address = "10.0.0.9"
        controller.configure(settings, now: 10)
        if drivers.last?.startedAddress != .some("10.0.0.9") || drivers.last?.startedTarget != .some(nil) {
            failures.append("An entered address did not take precedence over the selected console")
        }

        let connected = MixerConnectionController.Phase.connected(MixerIdentity(
            address: "10.0.0.20",
            name: "X32-FOH",
            model: "X32",
            firmware: "4"
        ))
        if MixerBridgeNotice.text(for: .waitingToRetry, target: target)?.contains("X32-FOH") != true
            || MixerBridgeNotice.text(for: .connecting, target: target)?.contains("X32-FOH") != true
            || MixerBridgeNotice.text(for: .waitingToRetry) != nil
            || MixerBridgeNotice.text(for: connected, target: target) != nil {
            failures.append("The meter bridge did not name the selected console it waits for")
        }
    }

    private static func testConsoleSwitchClearsNames(_ failures: inout [String]) {
        var drivers: [FakeDriver] = []
        let controller = MixerConnectionController { kind in
            guard kind != .none else { return nil }
            let driver = FakeDriver()
            drivers.append(driver)
            return driver
        }
        var settings = MixerSettings()
        settings.kind = .behringerWing
        settings.preferredConsole = PreferredMixer(kind: .behringerWing, name: "FOH", model: "wing", serial: "S1")
        controller.configure(settings, now: 0)
        drivers.last?.update = MixerDriverUpdate(
            state: .connected(MixerIdentity(address: "10.0.0.5", name: "FOH", model: "wing", firmware: "3")),
            secondsSinceMeterData: 0.02,
            stripCounts: ["in.LCL": 2],
            names: ["ch": [0: "Kick"]]
        )
        controller.tick(now: 0)
        func channelName() -> String? {
            controller.sections.first(where: { $0.id == "ch" })?.strips.first?.name
        }
        func connectorCount() -> Int? {
            controller.sections.first(where: { $0.id == "in.LCL" })?.strips.count
        }
        if channelName() != "Kick" || connectorCount() != 2 {
            failures.append("Console switch test did not apply the first console's names")
            return
        }

        if let dca = settings.kind.sections.first(where: { $0.id == "dca" }) {
            settings.setVisible(dca, false)
        }
        controller.configure(settings, now: 1)
        if channelName() != "Kick" || connectorCount() != 2 {
            failures.append("Changing the sections of the same console lost its names")
        }

        settings.preferredConsole = PreferredMixer(kind: .behringerWing, name: "MON", model: "wing", serial: "S2")
        controller.configure(settings, now: 2)
        if channelName() != "" || connectorCount() != 0 {
            failures.append("Names of the previous console stayed after selecting another console")
        }

        drivers.last?.update = MixerDriverUpdate(
            state: .connected(MixerIdentity(address: "10.0.0.7", name: "MON", model: "wing", firmware: "3")),
            secondsSinceMeterData: 0.02,
            names: ["ch": [0: "Vox"]]
        )
        controller.tick(now: 2)
        settings.address = "10.0.0.9"
        controller.configure(settings, now: 3)
        if channelName() != "" {
            failures.append("Names of the previous console stayed after entering another address")
        }
    }

    private static func testWingDiscoveryTarget(_ failures: inout [String]) {
        let replies = [
            "WING,10.0.0.7,MON,wing-compact,S2,3.1",
            "WING,10.0.0.5,FOH,wing-rack,S1,3.1"
        ].compactMap { WingConsoleInfo(discoveryReply: $0) }
        guard replies.count == 2 else {
            failures.append("WING discovery target test replies were not read")
            return
        }
        if WingMixerDriver.discoveryFilter(for: nil) != nil {
            failures.append("WING discovery without a selected console must take the first reply")
        }
        let target = PreferredMixer(kind: .behringerWing, name: "FOH", model: "wing-rack", serial: "S1")
        guard let filter = WingMixerDriver.discoveryFilter(for: target) else {
            failures.append("WING discovery did not use the selected console")
            return
        }
        if replies.first(where: filter)?.serial != "S1" {
            failures.append("WING discovery connected to another console that answered first")
        }
        if filter(replies[0]) {
            failures.append("WING discovery accepted a console other than the selected one")
        }
        let x32Target = PreferredMixer(kind: .behringerX32, name: "FOH", model: "wing-rack")
        if let x32Filter = WingMixerDriver.discoveryFilter(for: x32Target),
           replies.contains(where: x32Filter) {
            failures.append("WING discovery accepted a console selected as another type")
        }
    }

    private static func testX32ConsoleInfo(_ failures: inout [String]) {
        if X32Protocol.xinfoRequest != Array("/xinfo\0\0,\0\0\0".utf8) {
            failures.append("X32 xinfo request is not a read without arguments")
        }
        let reply = "/xinfo\0\0,ssss\0\0\0" + "192.168.0.64\0\0\0\0" + "X32-02-4A-53\0\0\0\0"
            + "X32C\0\0\0\0" + "2.10\0\0\0\0"
        guard let message = X32Message(packet: Array(reply.utf8)),
              let info = X32ConsoleInfo(message: message) else {
            failures.append("X32 xinfo reply was not read")
            return
        }
        let expected = X32ConsoleInfo(
            ip: "192.168.0.64",
            name: "X32-02-4A-53",
            model: "X32C",
            firmware: "2.10"
        )
        if info != expected {
            failures.append("X32 xinfo reply fields were read incorrectly")
        }
        let infoReply = "/info\0\0\0,ssss\0\0\0V2.05\0\0\0osc-server\0\0X32\0" + "2.12\0\0\0\0"
        if let other = X32Message(packet: Array(infoReply.utf8)), X32ConsoleInfo(message: other) != nil {
            failures.append("An X32 info reply was taken for an xinfo reply")
        }
        let short = "/xinfo\0\0,ss\0" + "192.168.0.64\0\0\0\0" + "X32\0"
        if let message = X32Message(packet: Array(short.utf8)), X32ConsoleInfo(message: message) != nil {
            failures.append("An incomplete X32 xinfo reply was accepted")
        }

        if X32MixerDriver.discoveryFilter(for: nil) != nil {
            failures.append("X32 discovery without a selected console must take the first reply")
        }
        let target = PreferredMixer(kind: .behringerX32, name: "X32-02-4A-53", model: "X32C")
        guard let filter = X32MixerDriver.discoveryFilter(for: target) else {
            failures.append("X32 discovery did not use the selected console")
            return
        }
        let other = X32ConsoleInfo(ip: "192.168.0.65", name: "X32-MON", model: "X32C", firmware: "2.10")
        if filter(other, "192.168.0.65") || !filter(info, "192.168.0.64") {
            failures.append("X32 discovery did not select the selected console by name and model")
        }
        let byAddress = PreferredMixer(kind: .behringerX32, model: "X32C", address: "192.168.0.64")
        guard let addressFilter = X32MixerDriver.discoveryFilter(for: byAddress) else {
            failures.append("X32 discovery did not use a selected console without a name")
            return
        }
        if !addressFilter(info, "192.168.0.64") || addressFilter(other, "192.168.0.65") {
            failures.append("X32 discovery did not select a console without a name by its sender")
        }
    }

    // MARK: - Console RTA

    /// Examples from "Unofficial X32/M32 OSC Remote Protocol", /meters/15.
    private static func testX32RTADecoding(_ failures: inout [String]) {
        var blob: [UInt8] = [50, 0, 0, 0, 0x00, 0x80, 0x00, 0xc0, 0x40, 0xe0, 0xff, 0xff]
        blob += [UInt8](repeating: 0, count: 48 * 4)
        guard let levels = X32Protocol.rtaLevels(blob: blob), levels.count == 100 else {
            failures.append("X32 RTA page was not decoded into 100 bands")
            return
        }
        if levels[0] != -128 || levels[1] != -64 || levels[2] != -31.75
            || levels[3] != -0.003_906_25 || levels[99] != 0 {
            failures.append("X32 RTA levels were not decoded as signed 1/256 dB, lower half first")
        }
        if X32Protocol.rtaLevels(blob: Array(blob.dropLast())) != nil {
            failures.append("A short X32 RTA page was accepted")
        }
        var wrongCount = blob
        wrongCount[0] = 49
        if X32Protocol.rtaLevels(blob: wrongCount) != nil {
            failures.append("An X32 RTA page with a wrong value count was accepted")
        }
        if X32Protocol.rtaLevels(blob: []) != nil || X32Protocol.rtaLevels(blob: [50, 0, 0]) != nil {
            failures.append("A truncated X32 RTA page was accepted")
        }

        let reply = Array("/meters/15\0\0,b\0\0".utf8) + [0, 0, 0, UInt8(blob.count)] + blob
        guard let message = X32Message(packet: reply),
              X32Protocol.meterPage(address: message.address) == X32Protocol.rtaPage,
              case .blob(let received)? = message.arguments.first,
              X32Protocol.rtaLevels(blob: received) == levels else {
            failures.append("X32 RTA reply was not read")
            return
        }

        let frequencies = X32MixerDriver.rtaBandFrequencies
        if frequencies.count != X32Protocol.rtaBandCount
            || frequencies.first != 20 || frequencies.last != 18_660
            || zip(frequencies, frequencies.dropFirst()).contains(where: { $0 >= $1 }) {
            failures.append("X32 RTA band frequencies do not match the protocol table")
        }
    }

    private static func testX32RTAStaleness(_ failures: inout [String]) {
        let staleAfter = MixerConnectionController.Timing().staleLevelsAfter
        let levels = [Float](repeating: -40, count: 100)
        if X32MixerDriver.rtaFrame(levels: levels, age: staleAfter / 2, staleAfter: staleAfter)?.levels
            != levels {
            failures.append("Fresh X32 RTA levels were not shown")
        }
        if X32MixerDriver.rtaFrame(levels: levels, age: staleAfter, staleAfter: staleAfter) != nil {
            failures.append("A stale X32 RTA page stayed on the display")
        }
        if X32MixerDriver.rtaFrame(levels: levels, age: nil, staleAfter: staleAfter) != nil
            || X32MixerDriver.rtaFrame(levels: nil, age: 0, staleAfter: staleAfter) != nil
            || X32MixerDriver.rtaFrame(levels: [], age: 0, staleAfter: staleAfter) != nil {
            failures.append("X32 RTA levels without a page or a reception time were shown")
        }
        // Bridge pages keep arriving while the analyzer page stopped.
        let channels = X32MixerDriver.definitions.filter { $0.descriptor.id == "ch" }
        let bridge = X32MixerDriver.levels(
            for: channels,
            pages: [0: [Float](repeating: 1, count: 70)],
            ages: [0: 0.05, X32Protocol.rtaPage: staleAfter * 2],
            staleAfter: staleAfter
        )
        if bridge["ch"]?.count != 32 {
            failures.append("A stale X32 RTA page hid the meter bridge")
        }
    }

    private static func testX32RTASettings(_ failures: inout [String]) {
        let reply = Array("/-prefs/rta/source\0\0,i\0\0".utf8) + [0, 0, 0, 5]
        let expected: [X32Message.Argument] = [.int(5)]
        guard let message = X32Message(packet: reply),
              message.address == X32MixerDriver.rtaSourceAddress,
              message.arguments == expected else {
            failures.append("X32 integer parameter reply was not read")
            return
        }

        let source = X32MixerDriver.rtaSourceAddress
        let tap = X32MixerDriver.rtaTapAddress
        let detector = X32MixerDriver.rtaDetectorAddress
        let info = X32MixerDriver.rtaInfo(parameters: [source: 5, tap: 1, detector: 0])
        if info != MixerRTAInfo(source: "Ch04", tap: L10n.text("Po EQ"), detector: "RMS") {
            failures.append("X32 RTA settings were not named")
        }
        let labels: [Int32: String] = [
            1: "Monitor", 2: "Ch01", 33: "Ch32", 34: "Aux1", 41: "Aux8",
            42: "FX1L", 43: "FX1R", 49: "FX4R", 50: "Bus01", 65: "Bus16",
            66: "Mtx1", 71: "Mtx6", 72: "Main", 73: "Mono"
        ]
        for (value, label) in labels where X32MixerDriver.rtaSourceLabel(value) != label {
            failures.append("X32 RTA source \(value) was not named \(label)")
        }
        if X32MixerDriver.rtaSourceLabel(0) != nil
            || X32MixerDriver.rtaSourceLabel(74) != nil
            || X32MixerDriver.rtaSourceLabel(-1) != nil {
            failures.append("An X32 RTA source without a strip was given a name")
        }
        let none = X32MixerDriver.rtaInfo(parameters: [source: 0, tap: 0, detector: 1])
        if none != MixerRTAInfo(sourceIsNone: true, tap: L10n.text("Před EQ"), detector: "PEAK") {
            failures.append("X32 RTA without a source was not reported")
        }
        if X32MixerDriver.rtaInfo(parameters: [source: 99, tap: 7, detector: 9]) != MixerRTAInfo()
            || X32MixerDriver.rtaInfo(parameters: [:]) != MixerRTAInfo() {
            failures.append("Unknown or missing X32 RTA settings were shown")
        }
    }

    private static func testWingRTARequest(_ failures: inout [String]) {
        let rtaOnly: [UInt8] = [0xdf, 0xd3, 0xd4, 0, 0, 0, 1, 0xdc, 0xaa, 0xde, 0xdf, 0xd1]
        if WingProtocol.meterRequest(reportID: 1, meters: [.rta]) != rtaOnly {
            failures.append("WING RTA meter request must carry only its type")
        }
        let mixed: [UInt8] = [
            0xdf, 0xd3, 0xd4, 0, 0, 0, 1, 0xdc, 0xa0, 0x01, 0xa7, 0x02, 0xaa, 0xde, 0xdf, 0xd1
        ]
        let meters: [WingMeter] = [
            WingMeter(kind: .channel, index: 1), WingMeter(kind: .source, index: 2), .rta
        ]
        if WingProtocol.meterRequest(reportID: 1, meters: meters) != mixed {
            failures.append("Indexed WING meters changed next to the RTA")
        }
        if WingMeter.Kind.rta.hasIndex || !WingMeter.Kind.output.hasIndex {
            failures.append("Only the WING RTA meter has no index")
        }
    }

    private static func testWingRTAMeasurement(_ failures: inout [String]) {
        let ch0 = WingMeter(kind: .channel, index: 0)
        let groups = [
            WingMeterGroup(meters: [ch0], isRequired: true),
            WingMeterGroup(meters: [.rta], isRequired: false)
        ]
        var present = WingGroupMeasurement(groups: groups)
        if present.start() != .request([ch0])
            || present.receive(length: 8) != .request([ch0, .rta])
            || present.receive(length: 8) != nil
            || present.receive(length: 128) != .finished(lengths: [8, 120]) {
            failures.append("The WING RTA group was not measured after the sections")
        }
        var absent = WingGroupMeasurement(groups: groups)
        if absent.start() != .request([ch0])
            || absent.receive(length: 8) != .request([ch0, .rta])
            || absent.receive(length: 8) != nil
            || absent.timeout() != .finished(lengths: [8, 0]) {
            failures.append("A WING console without RTA data ended or blocked the session")
        }
        let report = [Int16](repeating: 0, count: 8) + [Int16](repeating: -2_560, count: 120)
        guard let split = WingProtocol.split(report, lengths: [8, 120]), split.count == 2 else {
            failures.append("A WING report with an RTA group was not split")
            return
        }
        if WingMixerDriver.rtaFrame(from: split[1])?.levels != [Float](repeating: -10, count: 120) {
            failures.append("WING RTA levels were not decoded in 1/256 dB")
        }
        if WingMixerDriver.rtaFrame(from: []) != nil {
            failures.append("An empty WING RTA group was shown")
        }
        if WingMixerDriver.rtaFrame(from: [Int16](repeating: 0, count: 130))?.levels.count != 120
            || WingMixerDriver.rtaFrame(from: [256, -256])?.levels != [1, -1] {
            failures.append("A WING RTA group of an unexpected length was not limited safely")
        }

        let frequencies = WingMixerDriver.rtaBandFrequencies
        if frequencies.count != 120
            || abs(frequencies[0] - 20) > 1e-9
            || abs(frequencies[12] - 40) > 1e-9
            || zip(frequencies, frequencies.dropFirst()).contains(where: { $0 >= $1 }) {
            failures.append("WING RTA bands are not 1/12 octave from 20 Hz")
        }
    }

    private static func testWingStreamIntegers(_ failures: inout [String]) {
        var parser = WingStreamParser()
        let node = Int32(bitPattern: 0x0102_0304)
        let hash: [UInt8] = [0xd7, 0x01, 0x02, 0x03, 0x04]
        func values(_ bytes: [UInt8]) -> [WingNodeValue.Value] {
            let received = parser.consumeValues(bytes)
            if received.contains(where: { $0.node != node }) {
                failures.append("WING value was assigned to the wrong node")
            }
            return received.map(\.value)
        }

        if values([0xdf, 0xd1] + hash + [0x00, 0x01, 0x05, 0x3f])
            != [.integer(0), .integer(1), .integer(5), .integer(63)] {
            failures.append("Small WING integers were not decoded")
        }
        if values(hash + [0xd3, 0xff, 0xfe]) != [.integer(-2)]
            || values(hash + [0xd4, 0x00, 0x01, 0x00, 0x00]) != [.integer(65_536)]
            || values(hash + [0xd4, 0xff, 0xff, 0xff, 0xff]) != [.integer(-1)] {
            failures.append("WING 16-bit or 32-bit integers were not decoded")
        }
        let first = values(hash + [0xd3, 0x01])
        let second = values([0x00])
        if !first.isEmpty || second != [.integer(256)] {
            failures.append("A WING integer split across chunks was not decoded")
        }
        // Float bytes that look like other tokens are skipped whole.
        if values(hash + [0xd5, 0x3f, 0x80, 0x00, 0x00, 0xd6, 0x00, 0x01, 0xd3, 0x05, 0x07])
            != [.integer(7)] {
            failures.append("WING float values were not skipped")
        }
        if values(hash + [0x84] + Array("PREEQ".utf8)) != [.text("PREEQ")] {
            failures.append("WING text value was not reported with the integers")
        }
        if !values([0xda, 0x05]).isEmpty {
            failures.append("WING integer after navigation was given the last hashed node")
        }

        var textParser = WingStreamParser()
        let texts = textParser.consume([0xdf, 0xd1] + hash + [0x05, 0xd3, 0x00, 0x07, 0x80, 0x41])
        if texts.map(\.text) != ["A"] {
            failures.append("WING integers reached the text values")
        }
    }

    private static func testWingRTASettings(_ failures: inout [String]) {
        let labels: [Int32: String] = [
            1: "CH 1", 40: "CH 40", 41: "AUX 1", 48: "AUX 8", 49: "BUS 1",
            64: "BUS 16", 65: "MAIN 1", 68: "MAIN 4", 69: "MTX 1", 76: "MTX 8"
        ]
        for (index, label) in labels where WingMixerDriver.rtaSourceLabel(index) != label {
            failures.append("WING RTA source \(index) was not named \(label)")
        }
        if WingMixerDriver.rtaSourceLabel(0) != nil
            || WingMixerDriver.rtaSourceLabel(77) != nil
            || WingMixerDriver.rtaSourceLabel(-1) != nil {
            failures.append("A WING RTA source without a strip was given a name")
        }

        let source = WingMixerDriver.rtaSourceNode
        let tap = WingMixerDriver.rtaTapNode
        let detector = WingMixerDriver.rtaDetectorNode
        let info = WingMixerDriver.rtaInfo(values: [
            source: .integer(3), tap: .text("PREEQ"), detector: .text("RMS")
        ])
        if info != MixerRTAInfo(source: "CH 3", tap: L10n.text("Před EQ"), detector: "RMS") {
            failures.append("WING RTA settings were not named")
        }
        let asReceived = WingMixerDriver.rtaInfo(values: [
            source: .integer(0), tap: .text("MON.PH"), detector: .text("AVG")
        ])
        if asReceived != MixerRTAInfo(sourceIsNone: true, tap: "MON.PH", detector: "AVG") {
            failures.append("WING RTA tap or detector was not shown as received")
        }
        if WingMixerDriver.rtaInfo(values: [tap: .text("POSTEQ")]).tap != L10n.text("Po EQ") {
            failures.append("WING post-EQ tap was not named")
        }
        if WingMixerDriver.rtaInfo(values: [:]) != MixerRTAInfo()
            || WingMixerDriver.rtaInfo(values: [tap: .integer(3), detector: .text(" ")]) != MixerRTAInfo() {
            failures.append("Missing or unreadable WING RTA settings were shown")
        }
        if WingMixerDriver.rtaNodes != [792_206_572, -230_889_283, 3_015_320] {
            failures.append("WING RTA setting nodes changed")
        }
    }

    /// Nothing the analyzer sends may change the console.
    private static func testRTARequestsAreReadOnly(_ failures: inout [String]) {
        let meters = X32Message(packet: X32Protocol.meterRequest(page: X32Protocol.rtaPage))
        let page: [X32Message.Argument] = [.string("/meters/15")]
        if meters?.address != "/meters" || meters?.arguments != page {
            failures.append("X32 RTA page was not requested like other meters")
        }
        for address in X32MixerDriver.rtaParameterAddresses {
            let read = X32Message(packet: X32Protocol.read(address))
            if read?.address != address || read?.arguments.isEmpty != true {
                failures.append("X32 RTA setting \(address) was not only read")
            }
        }

        for node in WingMixerDriver.rtaNodes {
            let raw = UInt32(bitPattern: node)
            var expected: [UInt8] = [0xd7]
            for shift in [24, 16, 8, 0] {
                let byte = UInt8(truncatingIfNeeded: raw >> UInt32(shift))
                expected.append(byte)
                if byte == 0xdf { expected.append(0xde) }
            }
            expected.append(0xdc)
            if WingProtocol.nodeDataRequest(node: node) != expected {
                failures.append("WING RTA setting \(node) was not only read")
            }
        }
    }

    private static func testRTAConnection(_ failures: inout [String]) {
        var drivers: [FakeDriver] = []
        let timing = MixerConnectionController.Timing()
        let controller = MixerConnectionController(timing: timing) { kind in
            guard kind != .none else { return nil }
            let driver = FakeDriver()
            drivers.append(driver)
            return driver
        }
        let identity = MixerIdentity(address: "10.0.0.3", name: "X32", model: "X32", firmware: "4")

        var settings = MixerSettings()
        settings.kind = .behringerX32
        for section in settings.kind.sections {
            settings.setVisible(section, false)
        }
        controller.configure(settings, now: 0)
        if controller.phase != .noSectionsSelected || !drivers.isEmpty {
            failures.append("A mixer without sections connected without the RTA")
        }
        controller.configure(settings, includeRTA: true, now: 1)
        guard drivers.count == 1, let driver = drivers.last, controller.phase == .connecting else {
            failures.append("The RTA without meter bridge sections did not connect")
            return
        }
        if driver.startedIncludeRTA != true || !driver.startedSections.isEmpty {
            failures.append("The RTA was not requested from the driver")
        }

        let frame = MixerRTAFrame(levels: [-20, -30, -40])
        let info = MixerRTAInfo(source: "Ch01", tap: "Pre EQ", detector: "RMS")
        driver.update = MixerDriverUpdate(
            state: .connected(identity),
            secondsSinceMeterData: 0.02,
            rta: frame,
            rtaInfo: info
        )
        controller.tick(now: 1)
        if controller.rta != frame || controller.rtaInfo != info
            || controller.isRTAMissing || !controller.phase.isConnected {
            failures.append("Connected RTA levels or settings were not delivered")
        }

        // The analyzer data stops while other meters keep arriving.
        driver.update.rta = nil
        controller.tick(now: 1 + timing.staleLevelsAfter / 2)
        if controller.rta != nil || !controller.phase.isConnected || controller.isRTAMissing {
            failures.append("Missing RTA data was not cleared, or was reported before it was due")
        }
        controller.tick(now: 1 + timing.staleLevelsAfter)
        if !controller.isRTAMissing || controller.rtaInfo != info {
            failures.append("RTA data that stopped arriving was not reported")
        }

        driver.update.rta = frame
        driver.update.secondsSinceMeterData = timing.staleLevelsAfter
        controller.tick(now: 3)
        if controller.rta != nil {
            failures.append("Stale RTA levels stayed on the display")
        }
        // Every meter is stale: the connection state explains it, not the RTA.
        driver.update.rta = nil
        controller.tick(now: 3)
        if controller.isRTAMissing || !controller.phase.isConnected {
            failures.append("A full meter data outage was reported as missing RTA data")
        }
        driver.update.secondsSinceMeterData = timing.meterDataTimeout
        controller.tick(now: 3)
        if controller.phase != .waitingToRetry || controller.rta != nil
            || controller.rtaInfo != nil || controller.isRTAMissing {
            failures.append("A lost console kept its RTA data")
        }

        controller.tick(now: 3 + timing.retryDelay)
        controller.configure(settings, includeRTA: false, now: 10)
        if controller.phase != .noSectionsSelected || drivers.count != 2 || drivers.last?.stopCount != 1 {
            failures.append("Leaving the RTA kept a connection without sections")
        }

        settings = MixerSettings()
        settings.kind = .behringerX32
        controller.configure(settings, now: 20)
        let withoutRTA = drivers.count
        controller.configure(settings, includeRTA: true, now: 21)
        if drivers.count != withoutRTA + 1
            || drivers[withoutRTA - 1].stopCount != 1
            || drivers.last?.startedIncludeRTA != true
            || drivers.last?.startedSections.isEmpty != false {
            failures.append("Switching to the RTA did not restart the connection with the bridge sections")
        }

        controller.configure(settings, includeRTA: false, now: 22)
        drivers.last?.update = MixerDriverUpdate(
            state: .connected(identity),
            secondsSinceMeterData: 0.02,
            rta: frame,
            rtaInfo: info
        )
        controller.tick(now: 30)
        if controller.rta != nil || controller.rtaInfo != nil || controller.isRTAMissing
            || !controller.phase.isConnected {
            failures.append("RTA data was used while the RTA was not wanted")
        }
    }

    /// A driver learns at connection time which analyzer data a console sends,
    /// so analyzer data missing for long while other meters arrive reconnects.
    private static func testRTAMissingRetry(_ failures: inout [String]) {
        var drivers: [FakeDriver] = []
        let timing = MixerConnectionController.Timing()
        let controller = MixerConnectionController(timing: timing) { kind in
            guard kind != .none else { return nil }
            let driver = FakeDriver()
            drivers.append(driver)
            return driver
        }
        let identity = MixerIdentity(address: "10.0.0.4", name: "WING", model: "wing", firmware: "3")
        let frame = MixerRTAFrame(levels: [-20, -30])
        var settings = MixerSettings()
        settings.kind = .behringerWing
        controller.configure(settings, includeRTA: true, now: 0)
        guard let first = drivers.last else {
            failures.append("The RTA did not connect")
            return
        }
        first.update = MixerDriverUpdate(
            state: .connected(identity),
            secondsSinceMeterData: 0.02,
            levels: ["ch": [-20, -20]],
            rta: nil,
            rtaInfo: MixerRTAInfo()
        )
        let limit = timing.rtaMissingRetryAfter
        controller.tick(now: 0)
        controller.tick(now: limit - 0.1)
        if !controller.phase.isConnected || !controller.isRTAMissing
            || controller.levels["ch"] == nil || first.stopCount != 0 {
            failures.append("Missing RTA data reconnected too early or hid the meter bridge")
        }
        controller.tick(now: limit)
        if controller.phase != .waitingToRetry || first.stopCount != 1 {
            failures.append("RTA data missing while other meters arrive did not reconnect")
        }
        controller.tick(now: limit + timing.retryDelay - 0.1)
        if drivers.count != 1 {
            failures.append("Missing RTA data reconnected before the retry delay")
        }
        var now = limit + timing.retryDelay
        controller.tick(now: now)
        guard drivers.count == 2, let second = drivers.last else {
            failures.append("Missing RTA data did not start a new connection")
            return
        }

        // Interrupted gaps and stale meters do not count as missing RTA data.
        second.update = MixerDriverUpdate(
            state: .connected(identity),
            secondsSinceMeterData: 0.02,
            rta: nil
        )
        controller.tick(now: now)
        now += limit - 1
        controller.tick(now: now)
        second.update.rta = frame
        controller.tick(now: now)
        second.update.rta = nil
        now += limit - 1
        controller.tick(now: now)
        second.update.secondsSinceMeterData = timing.staleLevelsAfter
        now += limit
        controller.tick(now: now)
        if !controller.phase.isConnected || drivers.count != 2 || second.stopCount != 0 {
            failures.append("Interrupted or stale RTA gaps reconnected the console")
        }
        second.update.secondsSinceMeterData = 0.02
        second.update.rta = frame
        now += 2 * limit
        controller.tick(now: now)
        if !controller.phase.isConnected || controller.rta != frame || drivers.count != 2 {
            failures.append("Arriving RTA data reconnected the console")
        }
    }

    /// With only the analyzer wanted, a hidden meter keeps the connection alive.
    private static func testRTALiveness(_ failures: inout [String]) {
        let x32Channels = X32MixerDriver.definitions.filter { $0.descriptor.id == "ch" }
        if X32MixerDriver.meterPages(for: [], includeRTA: true) != [2, 15]
            || X32MixerDriver.meterPages(for: x32Channels, includeRTA: true) != [0, 15]
            || X32MixerDriver.meterPages(for: x32Channels, includeRTA: false) != [0]
            || !X32MixerDriver.meterPages(for: [], includeRTA: false).isEmpty {
            failures.append("X32 liveness page is not requested exactly when only the RTA is wanted")
        }
        let x32Hidden = X32MixerDriver.levels(
            for: [],
            pages: [2: [Float](repeating: 1, count: 49)],
            ages: [2: 0.05],
            staleAfter: 1
        )
        if !x32Hidden.isEmpty {
            failures.append("X32 liveness page was shown as levels")
        }

        let liveness = WingMixerDriver.livenessGroup
        let rtaGroup = WingMeterGroup(meters: [.rta], isRequired: false)
        let rtaOnly = WingMixerDriver.meterGroups(for: [], includeRTA: true)
        if rtaOnly.groups != [liveness, rtaGroup] || rtaOnly.rtaGroup != 1
            || !liveness.isRequired || liveness.meters.count != 4
            || !liveness.meters.allSatisfy({ $0.kind == .main }) {
            failures.append("WING RTA without sections has no required liveness group before the RTA")
        }
        let wingChannels = WingMixerDriver.definitions.filter { $0.descriptor.id == "ch" }
        let withSection = WingMixerDriver.meterGroups(for: wingChannels, includeRTA: true)
        if withSection.groups.count != 2 || withSection.groups.first?.meters != wingChannels.first?.meters
            || withSection.groups.last != rtaGroup || withSection.rtaGroup != 1 {
            failures.append("WING RTA group does not follow the section groups")
        }
        let bridgeOnly = WingMixerDriver.meterGroups(for: wingChannels, includeRTA: false)
        if bridgeOnly.groups.count != 1 || bridgeOnly.rtaGroup != nil {
            failures.append("WING groups changed without the RTA")
        }

        let rtaWords = [Int16](repeating: -2_560, count: 120)
        let hidden = WingMixerDriver.levels(
            for: [],
            reports: [[Int16](repeating: -256, count: 32), rtaWords]
        )
        if !hidden.levels.isEmpty || !hidden.stripCounts.isEmpty {
            failures.append("WING liveness or RTA group was shown as a section")
        }
        let shown = WingMixerDriver.levels(
            for: wingChannels,
            reports: [[Int16](repeating: -256, count: 320), rtaWords]
        )
        if shown.levels.count != 1 || shown.levels["ch"]?.count != 80 {
            failures.append("WING section levels changed next to the RTA group")
        }
    }

    private static func testRTADisplayMode(_ failures: inout [String]) {
        if AnalysisDisplayMode.combined.next != .meterBridge
            || AnalysisDisplayMode.meterBridge.next != .rta
            || AnalysisDisplayMode.rta.next != .wireless
            || AnalysisDisplayMode.wireless.next != .none {
            failures.append("The RTA is not cycled between the meter bridge and the wireless view")
        }
        let rta = AnalysisDisplayMode.rta
        if rta.usesAudioAnalysis || rta.showsSpectrogram || rta.showsTransferFunction {
            failures.append("The console RTA must not run the audio analysis")
        }
        let order = AnalysisDisplayMode.allCases
        if let bridge = order.firstIndex(of: .meterBridge), order.firstIndex(of: .rta) != bridge + 1 {
            failures.append("The RTA is not offered after the meter bridge")
        }
        if !MixerKind.none.rtaBandFrequencies.isEmpty
            || MixerKind.behringerX32.rtaBandFrequencies.count != 100
            || MixerKind.behringerWing.rtaBandFrequencies.count != 120 {
            failures.append("RTA bands do not match the console type")
        }
    }

    private static func testRTALayout(_ failures: inout [String]) {
        typealias Layout = MixerRTALayout
        for kind in [MixerKind.behringerX32, .behringerWing] {
            let frequencies = kind.rtaBandFrequencies
            for size in [CGSize(width: 1_600, height: 400), CGSize(width: 320, height: 120)] {
                let layout = Layout.compute(frequencies: frequencies, size: size)
                if layout.bands.map(\.index) != Array(frequencies.indices) {
                    failures.append("Not every \(kind) RTA band was placed at \(size)")
                    continue
                }
                if layout.plot.minY != Layout.headerHeight
                    || abs(layout.plot.maxY - (size.height - Layout.axisHeight)) > 0.001 {
                    failures.append("RTA bands overlap the header or the frequency axis at \(size)")
                }
                for (index, band) in layout.bands.enumerated() {
                    let frame = band.frame
                    if frame.minX < layout.plot.minX - 0.001 || frame.maxX > layout.plot.maxX + 0.001
                        || frame.width <= 0 || frame.height != layout.plot.height {
                        failures.append("\(kind) RTA band \(index) left the display at \(size)")
                    }
                    if index > 0, frame.minX < layout.bands[index - 1].frame.maxX - 0.001 {
                        failures.append("\(kind) RTA bands \(index - 1) and \(index) overlap at \(size)")
                    }
                    if let centre = layout.x(for: frequencies[index]),
                       centre < frame.minX - 0.001 || centre > frame.maxX + 1.001 {
                        failures.append("\(kind) RTA band \(index) is not at its frequency at \(size)")
                    }
                }
                if layout.ticks.first?.frequency != 20 || layout.ticks.last?.frequency != 20_000 {
                    failures.append("RTA frequency axis does not span 20 Hz to 20 kHz at \(size)")
                }
                if size.width >= 600,
                   zip(layout.ticks, layout.ticks.dropFirst()).contains(where: { $1.x - $0.x < 52 }) {
                    failures.append("RTA frequency labels crowd at \(size)")
                }
                if layout.gridLines.map(\.levelDB) != Array(stride(from: -80.0, through: 0, by: 10))
                    || layout.gridLines.filter(\.isLabeled).map(\.levelDB) != [-80, -60, -40, -20, 0] {
                    failures.append("RTA dB grid is not every 10 dB, labeled every 20 dB")
                }
            }
        }

        if Layout.fraction(levelDB: -80) != 0 || Layout.fraction(levelDB: 0) != 1
            || abs(Layout.fraction(levelDB: -40) - 0.5) > 1e-9 || Layout.fraction(levelDB: -120) != 0 {
            failures.append("RTA levels are not drawn from -80 dB to 0 dB")
        }
        if Layout.fraction(levelDB: -.infinity) != 0 || Layout.fraction(levelDB: 6) != 1 {
            failures.append("RTA levels outside the scale are not clamped")
        }
        if Layout.isClipped(levelDB: -0.2) || !Layout.isClipped(levelDB: -0.1)
            || !Layout.isClipped(levelDB: 0) || Layout.isClipped(levelDB: .nan) {
            failures.append("RTA clipping is not marked from -0.1 dB")
        }
        if Layout.frequencyLabel(20) != "20 Hz" || Layout.frequencyLabel(1_000) != "1 kHz"
            || Layout.frequencyLabel(2_500) != "2.5 kHz" {
            failures.append("RTA frequency labels differ from the spectrogram axis")
        }
        let x32 = MixerKind.behringerX32.rtaBandFrequencies
        if !Layout.compute(frequencies: [], size: CGSize(width: 800, height: 300)).bands.isEmpty
            || !Layout.compute(frequencies: [0, 100], size: CGSize(width: 800, height: 300)).bands.isEmpty
            || !Layout.compute(frequencies: x32, size: .zero).bands.isEmpty
            || !Layout.compute(frequencies: x32, size: CGSize(width: 20, height: 30)).bands.isEmpty {
            failures.append("RTA bands were placed without frequencies or room")
        }
    }

    private static func testRTAText(_ failures: inout [String]) {
        let full = MixerRTAText.header(for: MixerRTAInfo(source: "Ch01", tap: "Pre", detector: "RMS"))
        if full != L10n.format("Zdroj: %@", "Ch01") + " · Pre · RMS" {
            failures.append("RTA header does not list source, tap and detector")
        }
        if MixerRTAText.header(for: nil) != nil || MixerRTAText.header(for: MixerRTAInfo()) != nil {
            failures.append("RTA header was shown without settings")
        }
        if MixerRTAText.header(for: MixerRTAInfo(detector: "PEAK")) != "PEAK" {
            failures.append("Unknown RTA settings were not omitted from the header")
        }
        let none = MixerRTAText.header(for: MixerRTAInfo(sourceIsNone: true))
        if none != L10n.format("Zdroj: %@", L10n.text("žádný")) {
            failures.append("RTA header does not say that no source is selected")
        }

        let identity = MixerIdentity(address: "10.0.0.3", name: "X32", model: "X32", firmware: "4")
        let connected = MixerConnectionController.Phase.connected(identity)
        let target = PreferredMixer(kind: .behringerX32, name: "FOH")
        func notice(
            _ phase: MixerConnectionController.Phase,
            target: PreferredMixer? = nil,
            info: MixerRTAInfo? = nil,
            missing: Bool = false
        ) -> String? {
            MixerRTAText.notice(for: phase, target: target, info: info, isRTAMissing: missing)
        }
        if notice(connected, info: MixerRTAInfo(source: "Ch01")) != nil
            || notice(connected, missing: true) != MixerRTAText.noData
            || notice(connected, info: MixerRTAInfo(sourceIsNone: true)) != MixerRTAText.noSource {
            failures.append("RTA notices of a connected console are wrong")
        }
        if notice(.invalidAddress) != MixerBridgeNotice.invalidAddress
            || notice(.noSectionsSelected) != nil
            || notice(.connecting) != nil
            || notice(.waitingToRetry, target: target) != MixerBridgeNotice.unavailable(target) {
            failures.append("RTA notices do not follow the meter bridge's connection notices")
        }
        if MixerRTAText.accessibilityLabel(header: nil, notice: nil) != AnalysisDisplayMode.rta.title
            || MixerRTAText.accessibilityLabel(header: "A", notice: "B")
            != L10n.format("Analyzátor RTA, %@", "A, B") {
            failures.append("RTA accessibility label does not combine the header and the notice")
        }
    }
}
