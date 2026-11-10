import Foundation

/// A decoded OSC message of a Behringer X32 or Midas M32.
public struct X32Message: Equatable {
    public enum Argument: Equatable {
        case string(String)
        case int(Int32)
        case float(Float)
        case blob([UInt8])
    }

    public let address: String
    public let arguments: [Argument]

    public init?(packet: [UInt8]) {
        var offset = 0
        guard let address = Self.readString(packet, &offset),
              let tags = Self.readString(packet, &offset),
              tags.first == "," else { return nil }

        var arguments: [Argument] = []
        for tag in tags.dropFirst() {
            switch tag {
            case "s":
                guard let value = Self.readString(packet, &offset) else { return nil }
                arguments.append(.string(value))
            case "i":
                guard let value = Self.readBigEndianWord(packet, &offset) else { return nil }
                arguments.append(.int(Int32(bitPattern: value)))
            case "f":
                guard let value = Self.readBigEndianWord(packet, &offset) else { return nil }
                arguments.append(.float(Float(bitPattern: value)))
            case "b":
                guard let length = Self.readBigEndianWord(packet, &offset),
                      length <= UInt32(packet.count - offset) else { return nil }
                let end = offset + Int(length)
                arguments.append(.blob(Array(packet[offset..<end])))
                offset = min(packet.count, (end + 3) & ~3)
            default:
                return nil
            }
        }
        self.address = address
        self.arguments = arguments
    }

    private static func readString(_ packet: [UInt8], _ offset: inout Int) -> String? {
        guard offset < packet.count,
              let end = packet[offset...].firstIndex(of: 0) else { return nil }
        let text = String(decoding: packet[offset..<end], as: UTF8.self)
        offset = min(packet.count, (end + 4) & ~3)
        return text
    }

    private static func readBigEndianWord(_ packet: [UInt8], _ offset: inout Int) -> UInt32? {
        guard offset + 4 <= packet.count else { return nil }
        let value = packet[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset += 4
        return value
    }
}

/// Reply to `/xinfo`: the console's IP address, network name, model and
/// firmware version. Unlike `/info`, it names the console, so consoles of the
/// same model can be told apart.
public struct X32ConsoleInfo: Equatable {
    public let ip: String
    public let name: String
    public let model: String
    public let firmware: String

    public init(ip: String, name: String, model: String, firmware: String) {
        self.ip = ip
        self.name = name
        self.model = model
        self.firmware = firmware
    }

    public init?(message: X32Message) {
        guard message.address == X32Protocol.xinfoAddress else { return nil }
        let texts: [String] = message.arguments.compactMap {
            if case .string(let text) = $0 { return text }
            return nil
        }
        guard texts.count >= 4 else { return nil }
        self.init(ip: texts[0], name: texts[1], model: texts[2], firmware: texts[3])
    }
}

/// Read-only requests of the X32 remote protocol, as described in Patrick-Gilles
/// Maillot's "Unofficial X32/M32 OSC Remote Protocol". Nothing here can change a
/// console parameter: a message without arguments only reads a value.
public enum X32Protocol {
    public static let port: UInt16 = 10023
    public static let infoAddress = "/info"
    public static let xinfoAddress = "/xinfo"

    private static let meterAddressPrefix = "/meters/"

    public static var infoRequest: [UInt8] { read(infoAddress) }
    public static var xinfoRequest: [UInt8] { read(xinfoAddress) }

    /// A console sends a page about every 50 ms for 10 seconds after a request.
    public static func meterRequest(page: Int) -> [UInt8] {
        var message = padded(Array("/meters".utf8))
        message += padded(Array(",s".utf8))
        message += padded(Array("\(meterAddressPrefix)\(page)".utf8))
        return message
    }

    public static func read(_ address: String) -> [UInt8] {
        padded(Array(address.utf8)) + padded(Array(",".utf8))
    }

    public static func meterPage(address: String) -> Int? {
        guard address.hasPrefix(meterAddressPrefix) else { return nil }
        return Int(address.dropFirst(meterAddressPrefix.count))
    }

    /// A meter blob holds a little-endian value count and little-endian floats.
    /// Values are linear, with 1.0 at full scale and up to 8.0 (+18 dBFS).
    public static func meterValues(blob: [UInt8]) -> [Float]? {
        guard blob.count >= 4 else { return nil }
        let count = littleEndianWord(blob, at: 0)
        guard count <= UInt32((blob.count - 4) / 4) else { return nil }
        return (0..<Int(count)).map {
            Float(bitPattern: littleEndianWord(blob, at: 4 + $0 * 4))
        }
    }

    private static func littleEndianWord(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    /// OSC strings end with one to four zero bytes, to a multiple of four.
    private static func padded(_ bytes: [UInt8]) -> [UInt8] {
        bytes + [UInt8](repeating: 0, count: 4 - bytes.count % 4)
    }
}
