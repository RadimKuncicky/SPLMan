import ConsoleSockets
import Foundation

/// A meter block of the console. `index` is zero-based and at most 127.
public struct WingMeter: Equatable {
    public enum Kind: UInt8 {
        case channel = 0xa0
        case aux = 0xa1
        case bus = 0xa2
        case main = 0xa3
        case matrix = 0xa4
        case dca = 0xa5
        case source = 0xa7
        case output = 0xa8
    }

    public let kind: Kind
    public let index: UInt8

    public init(kind: Kind, index: UInt8) {
        self.kind = kind
        self.index = index
    }
}

/// Meters whose values are kept apart in the session's reports.
public struct WingMeterGroup: Equatable {
    public let meters: [WingMeter]
    /// Every console has the group, so one that does not report is an error
    /// rather than a missing card.
    public let isRequired: Bool

    public init(meters: [WingMeter], isRequired: Bool) {
        self.meters = meters
        self.isRequired = isRequired
    }
}

/// Reply to the `WING?` discovery datagram: `WING,ip,name,model,serial,firmware`.
public struct WingConsoleInfo: Equatable {
    public let ip: String
    public let name: String
    public let model: String
    public let serial: String
    public let firmware: String

    public init?(discoveryReply: String) {
        let fields = discoveryReply
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: ",")
        guard fields.count >= 6, fields[0] == "WING", !fields[1].isEmpty else { return nil }
        // The name may contain commas; the fields after it do not.
        let count = fields.count
        ip = fields[1]
        name = fields[2..<(count - 3)].joined(separator: ",")
        model = fields[count - 3]
        serial = fields[count - 2]
        firmware = fields[count - 1]
    }
}

/// Decides which datagrams belong to the session's console. Addresses are
/// compared as IPv4, so text that is not an IPv4 address never matches. While
/// the console's address is unknown, everything is accepted.
public struct WingConsoleFilter {
    private let consoleAddress: UInt32?

    /// - Parameter address: The console's address; a host name or nil leaves it unknown.
    public init(address: String?) {
        consoleAddress = address.flatMap(Self.ipv4)
    }

    public func acceptsMeters(from sender: String) -> Bool {
        guard let consoleAddress else { return true }
        return Self.ipv4(sender) == consoleAddress
    }

    /// Another console on the network answers discovery too. A console may name
    /// the address of another interface, so either its sender or the address it
    /// names must be the console's.
    public func acceptsConsoleInfo(_ info: WingConsoleInfo, from sender: String) -> Bool {
        guard let consoleAddress else { return true }
        return Self.ipv4(info.ip) == consoleAddress || Self.ipv4(sender) == consoleAddress
    }

    private static func ipv4(_ text: String) -> UInt32? {
        ConsoleUDPSocket.ipv4Address(text.trimmingCharacters(in: .whitespacesAndNewlines))?.s_addr
    }
}

/// Finds the number of values each group contributes to one combined report,
/// which does not say where a group starts. The number of connectors depends on
/// the model and its cards.
///
/// A request replaces the collection of its report, so all requests share one
/// report and the console only ever sends one. Each step requests the groups
/// measured so far plus the next one; a report longer than the measured total
/// tells the new group's length. Reports of the previous collection are never
/// longer than that total, so they cannot be mistaken for it.
public struct WingGroupMeasurement {
    public enum Step: Equatable {
        /// Send this collection and call `timeout()` if no step follows in time.
        case request([WingMeter])
        case finished(lengths: [Int])
        case failed(String)
    }

    public static let maximumAttempts = 3

    private let groups: [WingMeterGroup]
    /// Values per group, in group order, as far as they are known.
    public private(set) var lengths: [Int] = []
    private var attempts = 0
    /// Length of the latest report received for the current group.
    private var latestLength: Int?

    public init(groups: [WingMeterGroup]) {
        self.groups = groups
    }

    public mutating func start() -> Step {
        lengths = []
        return nextGroup()
    }

    /// Returns nil while the report does not contain the current group yet.
    public mutating func receive(length: Int) -> Step? {
        guard lengths.count < groups.count else { return nil }
        let base = measuredTotal
        guard length > base else {
            latestLength = length
            return nil
        }
        lengths.append(length - base)
        return nextGroup()
    }

    public mutating func timeout() -> Step {
        guard lengths.count < groups.count else { return .finished(lengths: lengths) }
        let group = groups[lengths.count]
        // The console answers, but without the group: it has no such card.
        if latestLength == measuredTotal, !group.isRequired {
            lengths.append(0)
            return nextGroup()
        }
        guard attempts >= Self.maximumAttempts else { return request() }
        if group.isRequired {
            return .failed("group \(lengths.count + 1) reported no values")
        }
        lengths.append(0)
        return nextGroup()
    }

    private var measuredTotal: Int { lengths.reduce(0, +) }

    private mutating func nextGroup() -> Step {
        while lengths.count < groups.count, groups[lengths.count].meters.isEmpty {
            lengths.append(0)
        }
        guard lengths.count < groups.count else { return .finished(lengths: lengths) }
        attempts = 0
        latestLength = nil
        return request()
    }

    private mutating func request() -> Step {
        attempts += 1
        // Groups without values would only repeat the question of their absence.
        let measured: [WingMeter] = zip(groups, lengths).flatMap { group, length in
            length > 0 ? group.meters : []
        }
        return .request(measured + groups[lengths.count].meters)
    }
}

/// A meter datagram: a 4-byte report identifier and big-endian signed 16-bit
/// values. Levels are in 1/256 dB.
public struct WingMeterReport: Equatable {
    public let reportID: UInt32
    public let words: [Int16]

    public init?(packet: [UInt8]) {
        guard packet.count >= 4 else { return nil }
        reportID = packet[0..<4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        var words: [Int16] = []
        words.reserveCapacity((packet.count - 4) / 2)
        var offset = 4
        while offset + 1 < packet.count {
            words.append(Int16(bitPattern: UInt16(packet[offset]) << 8 | UInt16(packet[offset + 1])))
            offset += 2
        }
        self.words = words
    }
}

/// Requests of the WING native protocol, as documented in "WING Remote Protocols".
/// Nothing here can change a console parameter.
public enum WingProtocol {
    public static let port: UInt16 = 2222
    public static let discoveryRequest = Array("WING?".utf8)
    public static let discoveryReplyPrefix = Array("WING,".utf8)

    private static let escapeCode: UInt8 = 0xdf
    private static let escapedEscapeCode: UInt8 = 0xde
    private static let controlChannel: [UInt8] = [0xdf, 0xd1]
    private static let meterChannel: [UInt8] = [0xdf, 0xd3]

    public static let selectControlChannel = controlChannel

    public static func meterPort(_ port: UInt16) -> [UInt8] {
        var payload: [UInt8] = [0xd3]
        payload += bigEndianBytes(port)
        return meterMessage(payload)
    }

    public static func meterRequest(reportID: UInt32, meters: [WingMeter]) -> [UInt8] {
        var payload: [UInt8] = [0xd4]
        payload += bigEndianBytes(reportID)
        payload.append(0xdc)
        for meter in meters {
            payload.append(meter.kind.rawValue)
            payload.append(meter.index)
        }
        payload.append(0xde)
        return meterMessage(payload)
    }

    /// A console stops sending a report 5 seconds after its last renewal.
    public static func meterRenewal(reportID: UInt32) -> [UInt8] {
        var payload: [UInt8] = [0xd4]
        payload += bigEndianBytes(reportID)
        return meterMessage(payload)
    }

    /// Cuts a report into consecutive groups of the given lengths, or returns nil
    /// when they do not add up to the whole report.
    public static func split(_ words: [Int16], lengths: [Int]) -> [[Int16]]? {
        guard lengths.reduce(0, +) == words.count else { return nil }
        var start = 0
        return lengths.map { length in
            defer { start += length }
            return Array(words[start..<(start + length)])
        }
    }

    /// Must be sent on the control channel.
    public static func nodeDataRequest(node: Int32) -> [UInt8] {
        var payload: [UInt8] = [0xd7]
        payload += bigEndianBytes(UInt32(bitPattern: node))
        payload.append(0xdc)
        return escaped(payload)
    }

    private static func meterMessage(_ payload: [UInt8]) -> [UInt8] {
        meterChannel + escaped(payload) + controlChannel
    }

    private static func escaped(_ payload: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(payload.count)
        for byte in payload {
            result.append(byte)
            if byte == escapeCode { result.append(escapedEscapeCode) }
        }
        return result
    }

    private static func bigEndianBytes<Value: FixedWidthInteger>(_ value: Value) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }
}

/// A text value of a console parameter received on the TCP stream.
public struct WingNodeText: Equatable {
    public let node: Int32
    public let text: String
}

/// Incremental decoder of the console's TCP stream. Chunks may split anywhere.
/// Only text values are reported, because that is all the bridge needs; other
/// values are skipped according to their token.
public struct WingStreamParser {
    private enum State {
        case token
        case skipping(Int)
        case textLength
        case text(remaining: Int)
        case nodeHash(remaining: Int)
        case definitionLength(remaining: Int)
        case definitionLongLength(remaining: Int)
    }

    private static let escapeCode: UInt8 = 0xdf
    private static let controlChannel = 1
    private static let channelBase: UInt8 = 0xd0
    private static let channelCount: UInt8 = 14

    private var isEscaped = false
    private var channel = -1
    private var state = State.token
    private var currentNode: Int32?
    private var accumulator: UInt32 = 0
    private var textBytes: [UInt8] = []

    public init() {}

    public mutating func consume(_ bytes: [UInt8]) -> [WingNodeText] {
        var results: [WingNodeText] = []
        for byte in bytes {
            for value in unframed(byte) {
                decode(value, &results)
            }
        }
        return results
    }

    /// Removes the channel framing, following the protocol's sample receive
    /// routine. Returns the bytes this input yields on the control channel.
    private mutating func unframed(_ byte: UInt8) -> [UInt8] {
        if byte == Self.escapeCode, !isEscaped {
            isEscaped = true
            return []
        }
        var output: [UInt8] = []
        var value = byte
        if isEscaped, byte != Self.escapeCode {
            isEscaped = false
            if byte == Self.escapeCode - 1 {
                value = Self.escapeCode
            } else if byte >= Self.channelBase, byte < Self.channelBase + Self.channelCount {
                channel = Int(byte - Self.channelBase)
                return []
            } else {
                output.append(Self.escapeCode)
            }
        }
        output.append(value)
        return channel == Self.controlChannel ? output : []
    }

    private mutating func decode(_ byte: UInt8, _ results: inout [WingNodeText]) {
        switch state {
        case .token:
            decodeToken(byte, &results)
        case .skipping(let remaining):
            state = remaining > 1 ? .skipping(remaining - 1) : .token
        case .textLength:
            textBytes = []
            state = .text(remaining: Int(byte) + 1)
        case .text(let remaining):
            textBytes.append(byte)
            if remaining > 1 {
                state = .text(remaining: remaining - 1)
            } else {
                emit(String(decoding: textBytes, as: UTF8.self), &results)
                state = .token
            }
        case .nodeHash(let remaining):
            accumulator = accumulator << 8 | UInt32(byte)
            if remaining > 1 {
                state = .nodeHash(remaining: remaining - 1)
            } else {
                currentNode = Int32(bitPattern: accumulator)
                state = .token
            }
        case .definitionLength(let remaining):
            accumulator = accumulator << 8 | UInt32(byte)
            if remaining > 1 {
                state = .definitionLength(remaining: remaining - 1)
            } else if accumulator == 0 {
                state = .definitionLongLength(remaining: 4)
            } else {
                state = .skipping(Int(accumulator))
            }
        case .definitionLongLength(let remaining):
            accumulator = accumulator << 8 | UInt32(byte)
            if remaining > 1 {
                state = .definitionLongLength(remaining: remaining - 1)
            } else {
                state = accumulator == 0 ? .token : .skipping(Int(accumulator))
            }
        }
    }

    private mutating func decodeToken(_ token: UInt8, _ results: inout [WingNodeText]) {
        switch token {
        case 0x80...0xbf:
            textBytes = []
            state = .text(remaining: Int(token - 0x80) + 1)
        case 0xc0...0xcf:
            state = .skipping(Int(token - 0xc0) + 1)
        case 0x40...0x7f, 0xda, 0xdb:
            // Navigation by index or through the tree leaves the hashed node, so
            // a following value belongs to a node this parser does not know.
            currentNode = nil
        case 0xd0:
            emit("", &results)
        case 0xd1:
            state = .textLength
        case 0xd2:
            currentNode = nil
            state = .skipping(2)
        case 0xd3:
            state = .skipping(2)
        case 0xd4, 0xd5, 0xd6:
            state = .skipping(4)
        case 0xd7:
            accumulator = 0
            state = .nodeHash(remaining: 4)
        case 0xd9:
            state = .skipping(1)
        case 0xdf:
            accumulator = 0
            state = .definitionLength(remaining: 2)
        default:
            // Integers and other tokens without further bytes.
            break
        }
    }

    private func emit(_ text: String, _ results: inout [WingNodeText]) {
        guard let currentNode else { return }
        results.append(WingNodeText(node: currentNode, text: text))
    }
}
