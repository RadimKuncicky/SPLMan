import Darwin
import Foundation

/// A non-blocking IPv4 UDP socket for talking to a mixing console. Network
/// framework cannot send broadcasts, which console discovery relies on. All
/// methods and the datagram handler belong to the queue given at creation.
public final class ConsoleUDPSocket {
    public let port: UInt16

    private static let receiveBufferBytes: Int32 = 256 * 1_024
    private static let maximumDatagramBytes = 8_192

    private let descriptor: Int32
    private let source: DispatchSourceRead
    private var isClosed = false

    public init?(
        queue: DispatchQueue,
        onDatagram: @escaping (_ datagram: [UInt8], _ sender: in_addr) -> Void
    ) {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return nil }

        var enabled: Int32 = 1
        var bufferBytes = ConsoleUDPSocket.receiveBufferBytes
        let optionSize = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &enabled, optionSize)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &bufferBytes, optionSize)

        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr = in_addr(s_addr: 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let isBound = withUnsafeMutablePointer(to: &local) { pointer -> Bool in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address -> Bool in
                guard Darwin.bind(descriptor, address, length) == 0 else { return false }
                return getsockname(descriptor, address, &length) == 0
            }
        }
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard isBound, flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(descriptor)
            return nil
        }

        self.descriptor = descriptor
        port = UInt16(bigEndian: local.sin_port)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler {
            ConsoleUDPSocket.readDatagrams(from: descriptor, onDatagram: onDatagram)
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        source.resume()
    }

    deinit { close() }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        source.cancel()
    }

    public func send(_ bytes: [UInt8], to destination: in_addr, port: UInt16) {
        guard !isClosed else { return }
        let socketDescriptor = descriptor
        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = port.bigEndian
        remote.sin_addr = destination
        // A refused send is not final: local network access may still be pending,
        // and callers repeat their requests.
        _ = bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &remote) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    sendto(
                        socketDescriptor,
                        buffer.baseAddress,
                        buffer.count,
                        0,
                        address,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
    }

    /// A Mac on Wi-Fi and Ethernet routes 255.255.255.255 through one of them, so
    /// the datagram also goes to the broadcast address of every network.
    public func broadcast(_ bytes: [UInt8], port: UInt16) {
        send(bytes, to: in_addr(s_addr: UInt32.max), port: port)
        for destination in Self.interfaceBroadcastAddresses() {
            send(bytes, to: destination, port: port)
        }
    }

    public static func ipv4Address(_ text: String) -> in_addr? {
        var address = in_addr()
        return inet_pton(AF_INET, text, &address) == 1 ? address : nil
    }

    public static func text(of address: in_addr) -> String {
        var copy = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &copy, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return ""
        }
        return String(cString: buffer)
    }

    private static func readDatagrams(
        from descriptor: Int32,
        onDatagram: ([UInt8], in_addr) -> Void
    ) {
        let capacity = maximumDatagramBytes
        var buffer = [UInt8](repeating: 0, count: capacity)
        while true {
            var sender = sockaddr_in()
            var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) { pointer -> Int in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address -> Int in
                    recvfrom(descriptor, &buffer, capacity, 0, address, &senderLength)
                }
            }
            guard count > 0 else { return }
            onDatagram(Array(buffer[0..<count]), sender.sin_addr)
        }
    }

    private static func interfaceBroadcastAddresses() -> [in_addr] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return [] }
        defer { freeifaddrs(start) }

        var addresses: [in_addr] = []
        for interface in sequence(first: start, next: { $0.pointee.ifa_next }) {
            let flags = Int32(bitPattern: interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_BROADCAST != 0,
                  flags & IFF_LOOPBACK == 0,
                  let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET),
                  let broadcast = interface.pointee.ifa_dstaddr else { continue }
            addresses.append(UnsafeRawPointer(broadcast).load(as: sockaddr_in.self).sin_addr)
        }
        return addresses
    }
}
