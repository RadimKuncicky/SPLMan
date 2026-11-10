import Foundation

/// The documented command sets. SLX-D and ULX-D frame messages the same way
/// but name and scale the metered properties differently. SLX-D+ (model names
/// ending in "+", such as SLXD4Q+) is SLX-D with linked transmitters, whose
/// model is read with LINK_TX_MODEL instead of TX_MODEL.
public enum ShureDialect: Equatable {
    case slxd
    case slxdPlus
    case ulxd
}

/// A receiver model this library can read. QLX-D has no published command
/// reference here; it uses the ULX-D set, its closest documented relative.
public struct ShureReceiverModel: Equatable {
    public let name: String
    public let dialect: ShureDialect
    public let channelCount: Int

    public init?(name: String) {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let families: [(prefix: String, dialect: ShureDialect)] = [
            ("SLXD4", .slxd),
            ("ULXD4", .ulxd),
            ("QLXD4", .ulxd)
        ]
        guard let family = families.first(where: { normalized.hasPrefix($0.prefix) }) else {
            return nil
        }
        self.name = normalized
        dialect = family.dialect == .slxd && normalized.hasSuffix("+") ? .slxdPlus : family.dialect
        // ULXD4D and SLXD4D are dual, ULXD4Q and SLXD4Q+ are quad.
        let suffix = normalized.dropFirst(family.prefix.count)
        channelCount = suffix.hasPrefix("Q") ? 4 : suffix.hasPrefix("D") ? 2 : 1
    }
}

/// One `< ... >` message split into fields. A `{...}` field is one token,
/// without its braces and padding.
public struct ShureMessage: Equatable {
    public let tokens: [String]

    public init(tokens: [String]) {
        self.tokens = tokens
    }
}

/// Splits the TCP byte stream into messages. Names may contain `<` and `>`, so
/// only markers outside braces delimit a message.
public struct ShureStreamParser {
    /// A receiver's messages are short, so this much without an end is corrupt.
    private static let maximumBufferedBytes = 16_384
    private static let messageStart = UInt8(ascii: "<")
    private static let messageEnd = UInt8(ascii: ">")
    private static let textStart = UInt8(ascii: "{")
    private static let textEnd = UInt8(ascii: "}")

    private var buffer: [UInt8] = []

    public init() {}

    public mutating func consume(_ bytes: [UInt8]) -> [ShureMessage] {
        buffer += bytes
        var messages: [ShureMessage] = []
        var keepFrom = buffer.count
        var position = 0
        while let start = buffer[position...].firstIndex(of: Self.messageStart) {
            guard let end = Self.endOfMessage(in: buffer, after: start) else {
                keepFrom = start
                break
            }
            messages.append(ShureMessage(tokens: Self.tokens(in: buffer[(start + 1)..<end])))
            position = end + 1
        }
        buffer.removeFirst(keepFrom)
        if buffer.count > Self.maximumBufferedBytes {
            buffer.removeAll()
        }
        return messages
    }

    private static func endOfMessage(in bytes: [UInt8], after start: Int) -> Int? {
        var isInsideText = false
        var index = start + 1
        while index < bytes.count {
            switch bytes[index] {
            case textStart: isInsideText = true
            case textEnd: isInsideText = false
            case messageEnd where !isInsideText: return index
            default: break
            }
            index += 1
        }
        return nil
    }

    private static func tokens(in bytes: ArraySlice<UInt8>) -> [String] {
        var tokens: [String] = []
        var current: [UInt8] = []
        var isInsideText = false
        for byte in bytes {
            if isInsideText {
                if byte == textEnd {
                    isInsideText = false
                    tokens.append(
                        String(decoding: current, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    current = []
                } else {
                    current.append(byte)
                }
            } else if byte == textStart {
                isInsideText = true
                current = []
            } else if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                if !current.isEmpty {
                    tokens.append(String(decoding: current, as: UTF8.self))
                    current = []
                }
            } else {
                current.append(byte)
            }
        }
        if !current.isEmpty {
            tokens.append(String(decoding: current, as: UTF8.self))
        }
        return tokens
    }
}

/// A receiver property. Values the receiver reports as unknown are nil, never a
/// number that could be read as an empty battery or a weak signal.
public enum ShureReport: Equatable {
    case model(String)
    case deviceID(String)
    case firmware(String)
    case channelName(channel: Int, name: String)
    case audioLevel(channel: Int, dBFS: Double?)
    /// SLX-D reports each antenna separately; ULX-D reports the one in use.
    case rfLevel(channel: Int, antenna: Int, dBm: Double?)
    case batteryBars(channel: Int, bars: Int?)
    case batteryMinutes(channel: Int, minutes: Int?)
    case transmitter(channel: Int, model: String?)
}

/// Only GET requests exist here: the library never changes anything on a
/// receiver, which also rules out METER_RATE, the documented way to get SAMPLE
/// messages. Metered properties are polled instead.
public enum ShureProtocol {
    public static let port: UInt16 = 2202

    private static let largestBatteryBars = 5
    private static let largestBatteryMinutes = 65_532

    public static var modelRequest: [UInt8] { request("MODEL") }
    public static var deviceRequests: [[UInt8]] { [request("DEVICE_ID"), request("FW_VER")] }

    public static func meterRequests(_ dialect: ShureDialect, channel: Int) -> [[UInt8]] {
        switch dialect {
        case .slxd, .slxdPlus: [request("\(channel) AUDIO_LEVEL_RMS")]
        case .ulxd: [request("\(channel) AUDIO_LVL")]
        }
    }

    public static func rfRequests(_ dialect: ShureDialect, channel: Int) -> [[UInt8]] {
        switch dialect {
        // The receiver answers with one report per antenna.
        case .slxd, .slxdPlus: [request("\(channel) RSSI")]
        case .ulxd: [request("\(channel) RX_RF_LVL")]
        }
    }

    public static func statusRequests(_ dialect: ShureDialect, channel: Int) -> [[UInt8]] {
        let properties: [String]
        switch dialect {
        case .slxd: properties = ["CHAN_NAME", "TX_MODEL", "TX_BATT_BARS", "TX_BATT_MINS"]
        // Slot 1 is the only transmitter slot of a channel.
        case .slxdPlus: properties = ["CHAN_NAME", "LINK_TX_MODEL 1", "TX_BATT_BARS", "TX_BATT_MINS"]
        case .ulxd: properties = ["CHAN_NAME", "TX_TYPE", "BATT_BARS", "BATT_RUN_TIME"]
        }
        return properties.map { request("\(channel) \($0)") }
    }

    /// Reads properties that do not depend on the model, which is how the model
    /// itself is learned.
    public static func deviceReport(from message: ShureMessage) -> ShureReport? {
        let tokens = message.tokens
        guard tokens.count == 3, tokens[0] == "REP" else { return nil }
        switch tokens[1] {
        case "MODEL": return .model(tokens[2])
        case "DEVICE_ID": return .deviceID(tokens[2])
        case "FW_VER": return .firmware(tokens[2])
        default: return nil
        }
    }

    public static func report(from message: ShureMessage, dialect: ShureDialect) -> ShureReport? {
        if let report = deviceReport(from: message) { return report }
        let tokens = message.tokens
        guard tokens.count >= 4, tokens[0] == "REP", let channel = Int(tokens[1]) else {
            return nil
        }
        let property = tokens[2]
        let value = tokens[3]
        if property == "CHAN_NAME" {
            return .channelName(channel: channel, name: value)
        }
        switch dialect {
        case .slxd, .slxdPlus:
            switch property {
            case "AUDIO_LEVEL_RMS":
                return .audioLevel(channel: channel, dBFS: scaled(value, valid: 0...120, offset: -120))
            case "RSSI":
                // The receivers have two antennas; anything else is not a reading.
                guard tokens.count >= 5, let antenna = Int(value), (1...2).contains(antenna) else {
                    return nil
                }
                return .rfLevel(
                    channel: channel,
                    antenna: antenna,
                    dBm: scaled(tokens[4], valid: 0...120, offset: -120)
                )
            case "TX_MODEL":
                return .transmitter(channel: channel, model: transmitterModel(value))
            case "LINK_TX_MODEL":
                // < REP x LINK_TX_MODEL slot model >
                guard tokens.count >= 5 else { return nil }
                return .transmitter(channel: channel, model: transmitterModel(tokens[4]))
            case "TX_BATT_BARS":
                return .batteryBars(channel: channel, bars: batteryBars(value))
            case "TX_BATT_MINS":
                return .batteryMinutes(channel: channel, minutes: batteryMinutes(value))
            default:
                return nil
            }
        case .ulxd:
            switch property {
            case "AUDIO_LVL":
                // 0 is the floor of the format, not a level of -50 dBFS: shown
                // as such, a silent microphone would light the bottom of a meter
                // whose scale reaches lower. Below the scale reads as silence.
                if Int(value) == 0 {
                    return .audioLevel(channel: channel, dBFS: -Double.infinity)
                }
                // The format allows 255, but above 0 dBFS the value is not a level.
                return .audioLevel(channel: channel, dBFS: scaled(value, valid: 0...50, offset: -50))
            case "RX_RF_LVL":
                // The format reaches +127 dBm; no received signal is above 0 dBm.
                return .rfLevel(
                    channel: channel,
                    antenna: 0,
                    dBm: scaled(value, valid: 0...128, offset: -128)
                )
            case "TX_TYPE":
                return .transmitter(channel: channel, model: transmitterModel(value))
            case "BATT_BARS":
                return .batteryBars(channel: channel, bars: batteryBars(value))
            case "BATT_RUN_TIME":
                return .batteryMinutes(channel: channel, minutes: batteryMinutes(value))
            default:
                return nil
            }
        }
    }

    private static func request(_ property: String) -> [UInt8] {
        Array("< GET \(property) >".utf8)
    }

    private static func scaled(_ text: String, valid: ClosedRange<Int>, offset: Double) -> Double? {
        guard let value = Int(text), valid.contains(value) else { return nil }
        return Double(value) + offset
    }

    private static func batteryBars(_ text: String) -> Int? {
        guard let bars = Int(text), (0...largestBatteryBars).contains(bars) else { return nil }
        return bars
    }

    private static func batteryMinutes(_ text: String) -> Int? {
        guard let minutes = Int(text), (0...largestBatteryMinutes).contains(minutes) else {
            return nil
        }
        return minutes
    }

    private static func transmitterModel(_ text: String) -> String? {
        text == "UNKNOWN" || text == "UNKN" || text.isEmpty ? nil : text
    }
}

/// What a receiver multicasts about itself. Shure does not document this for
/// third parties: the group, port and attributes come from a public analysis of
/// QLX-D traffic, so the ordinary TCP command connection stays the only source
/// of anything shown as fact about the receiver.
public struct ShureAdvertisement: Equatable {
    public static let multicastGroup = "239.255.254.253"
    public static let port: UInt16 = 8427

    public let model: String
    public let name: String

    public init?(datagram: [UInt8]) {
        let text = String(decoding: datagram, as: UTF8.self)
        guard let model = Self.attribute("acn-fctn", in: text) else { return nil }
        self.model = model
        name = Self.attribute("acn-uacn", in: text) ?? model
    }

    private static func attribute(_ key: String, in text: String) -> String? {
        guard let start = text.range(of: "(\(key)="),
              let end = text[start.upperBound...].firstIndex(of: ")") else { return nil }
        let value = text[start.upperBound..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
