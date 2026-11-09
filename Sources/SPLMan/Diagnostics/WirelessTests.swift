import CoreGraphics
import Foundation
import ShureKit

enum WirelessTests {
    private final class FakeDriver: WirelessDriver {
        var update = WirelessDriverUpdate(state: .connecting)
        var startedAddress: String?
        var stopCount = 0

        func start(address: String) { startedAddress = address }
        func poll() -> WirelessDriverUpdate { update }
        func stop() { stopCount += 1 }
    }

    static func run() -> [String] {
        var failures: [String] = []
        testModels(&failures)
        testRequests(&failures)
        testStreamParser(&failures)
        testSLXDReports(&failures)
        testULXDReports(&failures)
        testAdvertisement(&failures)
        testScanRange(&failures)
        testSettings(&failures)
        testConnection(&failures)
        testDiscoveredReceivers(&failures)
        testLayout(&failures)
        testRFScale(&failures)
        return failures
    }

    private static func message(_ text: String) -> ShureMessage? {
        var parser = ShureStreamParser()
        return parser.consume(Array(text.utf8)).first
    }

    private static func text(_ request: [UInt8]) -> String {
        String(decoding: request, as: UTF8.self)
    }

    private static func testModels(_ failures: inout [String]) {
        let expected: [(String, ShureDialect, Int)] = [
            ("SLXD4", .slxd, 1),
            ("SLXD4D", .slxd, 2),
            ("SLXD4+", .slxdPlus, 1),
            ("SLXD4D+", .slxdPlus, 2),
            ("SLXD4Q+", .slxdPlus, 4),
            ("ULXD4", .ulxd, 1),
            ("ULXD4D", .ulxd, 2),
            ("ULXD4Q", .ulxd, 4),
            ("QLXD4", .ulxd, 1)
        ]
        for (name, dialect, channels) in expected {
            let model = ShureReceiverModel(name: name)
            if model?.dialect != dialect || model?.channelCount != channels {
                failures.append("Shure model \(name) was not recognized correctly")
            }
        }
        if ShureReceiverModel(name: "  ulxd4q  ")?.channelCount != 4 {
            failures.append("Shure model name was not normalized")
        }
        for name in ["AD4Q", "P300", "Yamaha Console", ""] where ShureReceiverModel(name: name) != nil {
            failures.append("Unreadable device \(name) was accepted as a receiver")
        }
    }

    private static func testRequests(_ failures: inout [String]) {
        if text(ShureProtocol.modelRequest) != "< GET MODEL >" {
            failures.append("Shure model request differs from the command reference")
        }
        let metering: [(requests: [[UInt8]], expected: String)] = [
            (ShureProtocol.meterRequests(.slxd, channel: 1), "< GET 1 AUDIO_LEVEL_RMS >"),
            (ShureProtocol.meterRequests(.ulxd, channel: 2), "< GET 2 AUDIO_LVL >"),
            (ShureProtocol.rfRequests(.slxd, channel: 2), "< GET 2 RSSI >"),
            (ShureProtocol.rfRequests(.slxdPlus, channel: 4), "< GET 4 RSSI >"),
            (ShureProtocol.rfRequests(.ulxd, channel: 1), "< GET 1 RX_RF_LVL >")
        ]
        for entry in metering where entry.requests.map(text) != [entry.expected] {
            failures.append("Shure request differs from the command reference: \(entry.expected)")
        }

        var all = [ShureProtocol.modelRequest] + ShureProtocol.deviceRequests
        if ShureProtocol.statusRequests(.slxdPlus, channel: 3).map(text).contains("< GET 3 LINK_TX_MODEL 1 >") == false {
            failures.append("SLX-D+ transmitter model request differs from the command reference")
        }
        for dialect in [ShureDialect.slxd, .slxdPlus, .ulxd] {
            all += ShureProtocol.meterRequests(dialect, channel: 1)
            all += ShureProtocol.rfRequests(dialect, channel: 1)
            all += ShureProtocol.statusRequests(dialect, channel: 1)
        }
        for request in all where !(text(request).hasPrefix("< GET ") && text(request).hasSuffix(" >")) {
            failures.append("A request could change the receiver: \(text(request))")
        }
    }

    private static func testStreamParser(_ failures: inout [String]) {
        var parser = ShureStreamParser()
        let first = parser.consume(Array("noise < REP 1 CHAN_NAME {Lead Vox   ".utf8))
        if !first.isEmpty {
            failures.append("Shure parser returned an unfinished message")
        }
        let second = parser.consume(Array("         } >< REP 1 AUDIO_LVL 040 >< REP".utf8))
        if second != [
            ShureMessage(tokens: ["REP", "1", "CHAN_NAME", "Lead Vox"]),
            ShureMessage(tokens: ["REP", "1", "AUDIO_LVL", "040"])
        ] {
            failures.append("Shure parser did not rejoin messages split across reads")
        }
        if parser.consume(Array(" 2 AUDIO_LVL 041 >".utf8))
            != [ShureMessage(tokens: ["REP", "2", "AUDIO_LVL", "041"])] {
            failures.append("Shure parser lost the start of a split message")
        }
        // The name alphabet includes the characters that delimit messages.
        if message("< REP 1 CHAN_NAME {a>b<c    } >")?.tokens != ["REP", "1", "CHAN_NAME", "a>b<c"] {
            failures.append("Shure parser ended a message inside a name")
        }
        if message("< REP 1 CHAN_NAME {        } >")?.tokens != ["REP", "1", "CHAN_NAME", ""] {
            failures.append("Shure parser dropped an empty name")
        }
        if parser.consume(Array(repeating: UInt8(ascii: "x"), count: 100_000)) != [] {
            failures.append("Shure parser found a message in garbage")
        }
        var corrupt = ShureStreamParser()
        _ = corrupt.consume(Array("< REP {".utf8) + Array(repeating: UInt8(ascii: "x"), count: 100_000))
        if corrupt.consume(Array("< REP MODEL {ULXD4} >".utf8))
            != [ShureMessage(tokens: ["REP", "MODEL", "ULXD4"])] {
            failures.append("Shure parser did not recover from a message without an end")
        }
    }

    private static func report(_ text: String, _ dialect: ShureDialect) -> ShureReport? {
        message(text).flatMap { ShureProtocol.report(from: $0, dialect: dialect) }
    }

    /// Example values are those in the SLX-D command strings document.
    private static func testSLXDReports(_ failures: inout [String]) {
        let cases: [(String, ShureReport)] = [
            ("< REP MODEL {SLXD4                           } >", .model("SLXD4")),
            ("< REP DEVICE_ID {Name1   } >", .deviceID("Name1")),
            ("< REP 1 CHAN_NAME {Lead Vox                       } >", .channelName(channel: 1, name: "Lead Vox")),
            ("< REP 1 AUDIO_LEVEL_RMS 102 >", .audioLevel(channel: 1, dBFS: -18)),
            ("< REP 2 RSSI 1 083 >", .rfLevel(channel: 2, antenna: 1, dBm: -37)),
            ("< REP 1 TX_MODEL SLXD2 >", .transmitter(channel: 1, model: "SLXD2")),
            ("< REP 1 TX_MODEL UNKNOWN >", .transmitter(channel: 1, model: nil)),
            ("< REP 1 TX_BATT_BARS 004 >", .batteryBars(channel: 1, bars: 4)),
            ("< REP 1 TX_BATT_BARS 255 >", .batteryBars(channel: 1, bars: nil)),
            ("< REP 1 TX_BATT_MINS 00125 >", .batteryMinutes(channel: 1, minutes: 125)),
            ("< REP 1 TX_BATT_MINS 65533 >", .batteryMinutes(channel: 1, minutes: nil)),
            ("< REP 1 TX_BATT_MINS 65534 >", .batteryMinutes(channel: 1, minutes: nil)),
            ("< REP 1 TX_BATT_MINS 65535 >", .batteryMinutes(channel: 1, minutes: nil))
        ]
        for (text, expected) in cases where report(text, .slxd) != expected {
            failures.append("SLX-D report was read incorrectly: \(text)")
        }
        // Example values are those in the SLX-D+ command strings document.
        let plusCases: [(String, ShureReport)] = [
            ("< REP 4 AUDIO_LEVEL_RMS 102 >", .audioLevel(channel: 4, dBFS: -18)),
            ("< REP 3 RSSI 2 064 >", .rfLevel(channel: 3, antenna: 2, dBm: -56)),
            ("< REP 1 LINK_TX_MODEL 1 SLXD1+ >", .transmitter(channel: 1, model: "SLXD1+")),
            ("< REP 1 LINK_TX_MODEL 1 UNKNOWN >", .transmitter(channel: 1, model: nil)),
            ("< REP 2 TX_BATT_MINS 00360 >", .batteryMinutes(channel: 2, minutes: 360))
        ]
        for (text, expected) in plusCases where report(text, .slxdPlus) != expected {
            failures.append("SLX-D+ report was read incorrectly: \(text)")
        }
    }

    private static func testULXDReports(_ failures: inout [String]) {
        let cases: [(String, ShureReport)] = [
            ("< REP 3 AUDIO_LVL 032 >", .audioLevel(channel: 3, dBFS: -18)),
            ("< REP 3 AUDIO_LVL 255 >", .audioLevel(channel: 3, dBFS: nil)),
            ("< REP 1 RX_RF_LVL 078 >", .rfLevel(channel: 1, antenna: 0, dBm: -50)),
            ("< REP 1 RX_RF_LVL 255 >", .rfLevel(channel: 1, antenna: 0, dBm: nil)),
            ("< REP 1 BATT_BARS 002 >", .batteryBars(channel: 1, bars: 2)),
            ("< REP 1 BATT_BARS 255 >", .batteryBars(channel: 1, bars: nil)),
            ("< REP 1 BATT_RUN_TIME 00125 >", .batteryMinutes(channel: 1, minutes: 125)),
            ("< REP 1 BATT_RUN_TIME 65535 >", .batteryMinutes(channel: 1, minutes: nil)),
            ("< REP 1 TX_TYPE ULXD2 >", .transmitter(channel: 1, model: "ULXD2")),
            ("< REP 1 TX_TYPE UNKN >", .transmitter(channel: 1, model: nil))
        ]
        for (text, expected) in cases where report(text, .ulxd) != expected {
            failures.append("ULX-D report was read incorrectly: \(text)")
        }
        // The other dialect's properties and error replies are not readings.
        for text in ["< REP 1 AUDIO_LEVEL_RMS 102 >", "< REP ERR >", "< SAMPLE 1 ALL AX 090 040 >", "< REP x BATT_BARS 001 >"]
        where report(text, .ulxd) != nil {
            failures.append("A message that is no ULX-D reading was accepted: \(text)")
        }
    }

    private static func testAdvertisement(_ failures: inout [String]) {
        let attributes = "(acn-fctn=QLXD4),(acn-uacn=Stage L),"
            + "(cid=DD47E0D7-0000-11DD-A000-000EDDCCCCCC),(acn-services=esta.dmp)"
        let datagram: [UInt8] = [0x02, 0x07, 0x00, 0x00, 0xFF] + Array(attributes.utf8)
        let advertisement = ShureAdvertisement(datagram: datagram)
        if advertisement?.model != "QLXD4" || advertisement?.name != "Stage L" {
            failures.append("Shure advertisement was not read")
        }
        if ShureAdvertisement(datagram: Array("(acn-fctn=ULXD4D)".utf8))?.name != "ULXD4D" {
            failures.append("Shure advertisement without a name did not use its model")
        }
        if ShureAdvertisement(datagram: Array("(acn-uacn=Stage L)".utf8)) != nil
            || ShureAdvertisement(datagram: Array("(acn-fctn=)".utf8)) != nil
            || ShureAdvertisement(datagram: []) != nil {
            failures.append("An invalid Shure advertisement was accepted")
        }
    }

    private static func testScanRange(_ failures: inout [String]) {
        let hosts = ShureNetworkScanner.hostsToProbe(address: "192.168.1.20", netmask: "255.255.255.0")
        if hosts.count != 253 || hosts.first != "192.168.1.1" || hosts.last != "192.168.1.254"
            || hosts.contains("192.168.1.20") {
            failures.append("Scan did not cover exactly the other hosts of the network")
        }
        if ShureNetworkScanner.hostsToProbe(address: "10.1.2.3", netmask: "255.0.0.0").count != 253 {
            failures.append("Scan of a large network was not limited to one /24")
        }
        if ShureNetworkScanner.hostsToProbe(address: "10.0.0.17", netmask: "255.255.255.240")
            != (17...30).filter({ $0 != 17 }).map({ "10.0.0.\($0)" }) {
            failures.append("Scan left a small network")
        }
        if !ShureNetworkScanner.hostsToProbe(address: "10.0.0.1", netmask: "255.255.255.254").isEmpty
            || !ShureNetworkScanner.hostsToProbe(address: "invalid", netmask: "255.255.255.0").isEmpty {
            failures.append("Scan produced hosts for a network without any")
        }
    }

    private static func testSettings(_ failures: inout [String]) {
        var settings = WirelessSettings()
        settings.addresses = " 192.168.1.2, 192.168.1.3;192.168.1.2\nrx.local "
        if settings.manualAddresses != ["192.168.1.2", "192.168.1.3", "rx.local"] {
            failures.append("Wireless addresses were not split and deduplicated")
        }
        if !WirelessSettings().manualAddresses.isEmpty || WirelessSettings().isEnabled {
            failures.append("Wireless monitoring must be off without addresses by default")
        }
        do {
            var persisted = PersistedSettings()
            settings.isEnabled = true
            persisted.wireless = settings
            let encoded = try PropertyListEncoder().encode(persisted)
            if try PropertyListDecoder().decode(PersistedSettings.self, from: encoded) != persisted {
                failures.append("Wireless settings did not round-trip")
            }
            guard var object = try PropertyListSerialization.propertyList(
                from: encoded,
                format: nil
            ) as? [String: Any] else {
                failures.append("Wireless settings fixture could not be created")
                return
            }
            object.removeValue(forKey: "wireless")
            let older = try PropertyListSerialization.data(
                fromPropertyList: object,
                format: .binary,
                options: 0
            )
            if try PropertyListDecoder().decode(PersistedSettings.self, from: older).wireless
                != WirelessSettings() {
                failures.append("Settings from before wireless support did not use defaults")
            }
        } catch {
            failures.append("Wireless settings failed to encode or decode: \(error)")
        }
        if AnalysisDisplayMode.wireless.usesAudioAnalysis {
            failures.append("Wireless view must not run the audio analysis")
        }
    }

    private static func connected(
        name: String = "Vox",
        secondsSinceData: TimeInterval? = 0.1
    ) -> WirelessDriverUpdate {
        WirelessDriverUpdate(
            state: .connected,
            model: "ULXD4",
            deviceName: "Rack1",
            secondsSinceData: secondsSinceData,
            channels: [
                WirelessChannelReading(
                    number: 1,
                    name: name,
                    audioLevelDB: -20,
                    rfLevelDBm: -60,
                    batteryBars: 3,
                    batteryMinutes: 90,
                    transmitterModel: "ULXD2"
                )
            ]
        )
    }

    private static func enabled(_ addresses: String) -> WirelessSettings {
        var settings = WirelessSettings()
        settings.isEnabled = true
        settings.addresses = addresses
        return settings
    }

    private static func testConnection(_ failures: inout [String]) {
        var drivers: [FakeDriver] = []
        let timing = WirelessMonitorController.Timing()
        let controller = WirelessMonitorController(timing: timing) {
            let driver = FakeDriver()
            drivers.append(driver)
            return driver
        }

        controller.configure(WirelessSettings(), now: 0)
        if !drivers.isEmpty || !controller.receivers.isEmpty {
            failures.append("Wireless monitoring connected while switched off")
        }

        controller.configure(enabled("10.0.0.5"), now: 0)
        if drivers.count != 1 || drivers.last?.startedAddress != "10.0.0.5"
            || controller.receivers.first?.phase != .connecting {
            failures.append("Configured receiver did not start connecting")
        }
        controller.tick(now: timing.attemptTimeout - 1)
        if controller.receivers.first?.phase != .connecting {
            failures.append("Receiver attempt ended before its timeout")
        }
        controller.tick(now: timing.attemptTimeout)
        if controller.receivers.first?.phase != .unavailable || drivers[0].stopCount != 1 {
            failures.append("Receiver attempt did not time out")
        }
        var now = timing.attemptTimeout + timing.retryDelay
        controller.tick(now: now)
        if drivers.count != 2 || controller.receivers.first?.phase != .connecting {
            failures.append("Receiver was not retried")
        }

        drivers[1].update = connected()
        controller.tick(now: now)
        guard let channel = controller.channels.first else {
            failures.append("Connected receiver showed no channel")
            return
        }
        if controller.receivers.first?.phase != .connected
            || controller.receivers.first?.name != "Rack1"
            || channel.id != "10.0.0.5#1" || channel.name != "Vox" || !channel.isOnline
            || channel.batteryBars != 3 || channel.batteryMinutes != 90
            || channel.transmitterModel != "ULXD2" {
            failures.append("Connected receiver was not shown correctly")
        }
        if controller.levels[channel.id] != [-20, -60] {
            failures.append("Levels of a connected receiver were not provided")
        }

        drivers[1].update = connected(secondsSinceData: timing.staleLevelsAfter)
        controller.tick(now: now)
        if !controller.levels.isEmpty || controller.channels.first?.isOnline != true {
            failures.append("Levels must clear while the data is late")
        }

        drivers[1].update = connected(secondsSinceData: timing.dataTimeout)
        controller.tick(now: now)
        if controller.receivers.first?.phase != .unavailable {
            failures.append("Silent receiver was not treated as lost")
        }
        if controller.channels.first?.name != "Vox" || controller.channels.first?.isOnline != false
            || controller.channels.first?.batteryBars != nil {
            failures.append("Lost receiver must stay listed as offline, without old readings")
        }

        now += timing.retryDelay
        controller.tick(now: now)
        drivers[2].update = WirelessDriverUpdate(state: .unsupported, model: "AD4Q")
        controller.tick(now: now)
        if controller.receivers.first?.phase != .unsupported || controller.receivers.first?.model != "AD4Q" {
            failures.append("Unsupported model was not reported")
        }
        controller.tick(now: now + timing.retryDelay)
        if drivers.count != 3 {
            failures.append("Unsupported model was retried too soon")
        }
        controller.tick(now: now + timing.unsupportedRetryDelay)
        if drivers.count != 4 {
            failures.append("Unsupported model was never retried")
        }
        now += timing.unsupportedRetryDelay

        drivers[3].update = connected(name: "")
        controller.tick(now: now)
        if controller.channels.first?.name != "Rack1" {
            failures.append("Unnamed channel did not use the receiver's name")
        }

        drivers[3].update = WirelessDriverUpdate(state: .failed)
        controller.tick(now: now)
        if controller.receivers.first?.phase != .unavailable || drivers[3].stopCount != 1 {
            failures.append("Failed connection was not closed")
        }

        controller.configure(enabled(""), now: now)
        if !controller.receivers.isEmpty || !controller.channels.isEmpty {
            failures.append("Removed address stayed in use")
        }
        let count = drivers.count
        controller.tick(now: now + timing.unsupportedRetryDelay)
        if drivers.count != count {
            failures.append("Removed address was connected again")
        }
    }

    private static func testDiscoveredReceivers(_ failures: inout [String]) {
        var drivers: [FakeDriver] = []
        let controller = WirelessMonitorController {
            let driver = FakeDriver()
            drivers.append(driver)
            return driver
        }
        controller.setDiscovered(["10.0.0.9"], now: 0)
        if !drivers.isEmpty {
            failures.append("Discovery connected while monitoring is off")
        }

        controller.configure(enabled("10.0.0.10"), now: 0)
        controller.setDiscovered(["10.0.0.9", "10.0.0.10"], now: 0)
        if drivers.count != 2 || controller.receivers.map(\.address) != ["10.0.0.9", "10.0.0.10"] {
            failures.append("Discovered and configured receivers were not merged in address order")
        }
        if !controller.channels.isEmpty {
            failures.append("A receiver showed channels before it connected")
        }

        guard let discovered = drivers.first(where: { $0.startedAddress == "10.0.0.9" }) else {
            failures.append("Discovered receiver was not started")
            return
        }
        discovered.update = connected()
        controller.tick(now: 1)
        controller.setDiscovered([], now: 1)
        if controller.receivers.first(where: { $0.address == "10.0.0.9" })?.phase != .connected {
            failures.append("A working receiver was dropped when its advertisement ended")
        }
        if controller.receivers.first(where: { $0.address == "10.0.0.10" }) == nil {
            failures.append("A configured receiver was dropped with discovery")
        }

        discovered.update = WirelessDriverUpdate(state: .failed)
        controller.tick(now: 2)
        if controller.receivers.contains(where: { $0.address == "10.0.0.9" }) {
            failures.append("A lost receiver that is no longer advertised stayed listed")
        }

        controller.setDiscovered(["10.0.0.9"], now: 2)
        let other = WirelessMonitorController { FakeDriver() }
        other.configure(enabled("10.0.0.1"), now: 0)
        other.configure(WirelessSettings(), now: 0)
        if !other.receivers.isEmpty || other.isEnabled {
            failures.append("Switching monitoring off did not close its receivers")
        }
    }

    private static func testLayout(_ failures: inout [String]) {
        func channels(_ count: Int) -> [WirelessChannel] {
            (0..<count).map {
                WirelessChannel(id: "a#\($0)", number: $0 + 1, name: "Mic", isOnline: true)
            }
        }
        let size = CGSize(width: 1920, height: 480)
        if !WirelessMonitorLayout.compute(channels: [], size: size).columns.isEmpty
            || !WirelessMonitorLayout.compute(channels: channels(2), size: .zero).columns.isEmpty {
            failures.append("Wireless layout drew columns without channels or room")
        }
        for count in [1, 4, 16, 64, 300] {
            let columns = WirelessMonitorLayout.compute(channels: channels(count), size: size).columns
            if columns.count != count {
                failures.append("Wireless layout lost channels at \(count)")
            }
            for column in columns {
                for bar in [column.audioBar, column.rfBar] where bar.minX < column.frame.minX - 0.001
                    || bar.maxX > column.frame.maxX + 0.001
                    || bar.maxY > size.height {
                    failures.append("Wireless bar left its column at \(count) channels")
                }
                if column.audioBar.maxX > column.rfBar.minX {
                    failures.append("Wireless bars overlap at \(count) channels")
                }
            }
            if count <= 64, columns.last.map({ $0.frame.maxX > size.width }) ?? false {
                failures.append("Wireless columns left the display at \(count) channels")
            }
        }
        let wide = WirelessMonitorLayout.compute(channels: channels(1), size: size).columns[0]
        if !wide.showsName || !wide.showsBarLabels || !wide.showsBatteryMinutes {
            failures.append("A wide wireless column left out its text")
        }
        let narrow = WirelessMonitorLayout.compute(channels: channels(64), size: size).columns[0]
        if narrow.showsName || narrow.showsBatteryMinutes {
            failures.append("A narrow wireless column kept text that cannot fit")
        }
        // Must not crash on a display smaller than the header and footer.
        _ = WirelessMonitorLayout.compute(channels: channels(2), size: CGSize(width: 40, height: 10))
    }

    private static func testRFScale(_ failures: inout [String]) {
        typealias Scale = WirelessRFScale
        if Scale.fraction(-120) != 0 || Scale.fraction(0) != 1 || Scale.fraction(-.infinity) != 0 {
            failures.append("Signal strength left its bar")
        }
        if Scale.zone(-90) != .weak || Scale.zone(-85) != .fair
            || Scale.zone(-71) != .fair || Scale.zone(-70) != .strong {
            failures.append("Signal strength zones changed")
        }
    }
}
