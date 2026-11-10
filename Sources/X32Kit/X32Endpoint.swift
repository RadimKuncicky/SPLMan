import ConsoleSockets
import Foundation

/// A console address as the user enters it: an IPv4 address or a host name,
/// optionally followed by `:port`. Parsing is purely syntactic; a host name is
/// resolved only when connecting. IPv6 is not accepted because the console
/// socket is IPv4 only.
public struct X32Endpoint: Equatable {
    public let host: String
    public let port: UInt16

    private static let largestHostLength = 253
    private static let largestLabelLength = 63

    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }

        // One trailing dot marks a fully qualified name. It is dropped so the
        // stored host is the same name in a single canonical form (and an IPv4
        // literal stays a literal).
        var host = String(parts[0])
        if host.hasSuffix(".") { host.removeLast() }
        guard Self.isValidHost(host) else { return nil }

        var port = X32Protocol.port
        if parts.count == 2 {
            let digits = parts[1]
            guard !digits.isEmpty,
                  digits.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
                  let value = Int(digits),
                  (1...Int(UInt16.max)).contains(value) else { return nil }
            port = UInt16(value)
        }
        self.host = host
        self.port = port
    }

    /// An IPv4 literal, or a host name made of letters, digits, hyphens and
    /// underscores (the resolver accepts underscores, e.g. `X32_Rack`).
    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= largestHostLength else { return false }
        let isNumeric = host.utf8.allSatisfy {
            $0 == UInt8(ascii: ".") || ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
        }
        if isNumeric {
            return ConsoleUDPSocket.ipv4Address(host) != nil
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty
                && label.utf8.count <= largestLabelLength
                && !label.hasPrefix("-")
                && !label.hasSuffix("-")
                && label.utf8.allSatisfy(isHostCharacter)
        }
    }

    private static func isHostCharacter(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
            || byte == UInt8(ascii: "-")
            || byte == UInt8(ascii: "_")
    }
}
