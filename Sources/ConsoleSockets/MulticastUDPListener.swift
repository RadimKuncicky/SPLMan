import Darwin
import Foundation

/// The networks of this Mac that devices can be found on. VPN tunnels are left
/// out because they have no broadcast domain.
public enum ConsoleNetwork {
    public struct IPv4Interface {
        public let address: in_addr
        public let netmask: in_addr
    }

    public static func ipv4Interfaces() -> [IPv4Interface] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return [] }
        defer { freeifaddrs(start) }

        var interfaces: [IPv4Interface] = []
        for interface in sequence(first: start, next: { $0.pointee.ifa_next }) {
            let flags = Int32(bitPattern: interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_BROADCAST != 0,
                  flags & IFF_LOOPBACK == 0,
                  let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET),
                  let netmask = interface.pointee.ifa_netmask else { continue }
            interfaces.append(IPv4Interface(
                address: UnsafeRawPointer(address).load(as: sockaddr_in.self).sin_addr,
                netmask: UnsafeRawPointer(netmask).load(as: sockaddr_in.self).sin_addr
            ))
        }
        return interfaces
    }
}

/// Receives datagrams sent to an IPv4 multicast group on every network of this
/// Mac. It only listens. All methods and the datagram handler belong to the
/// queue given at creation.
public final class MulticastUDPListener {
    private let descriptor: Int32
    private let source: DispatchSourceRead
    private let group: in_addr
    private var isClosed = false

    public init?(
        group groupAddress: String,
        port: UInt16,
        queue: DispatchQueue,
        onDatagram: @escaping (_ datagram: [UInt8], _ sender: in_addr) -> Void
    ) {
        guard let group = ConsoleUDPSocket.ipv4Address(groupAddress) else { return nil }
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return nil }

        // Other software on this Mac, such as Wireless Workbench, may listen too.
        var enabled: Int32 = 1
        let optionSize = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &enabled, optionSize)
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEPORT, &enabled, optionSize)

        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = port.bigEndian
        local.sin_addr = in_addr(s_addr: 0)
        let length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let isBound = withUnsafeMutablePointer(to: &local) { pointer -> Bool in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address -> Bool in
                Darwin.bind(descriptor, address, length) == 0
            }
        }
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard isBound, flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(descriptor)
            return nil
        }

        self.descriptor = descriptor
        self.group = group
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler {
            ConsoleUDPSocket.readDatagrams(from: descriptor, onDatagram: onDatagram)
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        source.resume()
        joinGroup()
    }

    deinit { close() }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        source.cancel()
    }

    /// Joins on every current network. Call it again to cover networks that came
    /// up later; a network that has already joined simply refuses.
    public func joinGroup() {
        guard !isClosed else { return }
        for interface in ConsoleNetwork.ipv4Interfaces() {
            var request = ip_mreq()
            request.imr_multiaddr = group
            request.imr_interface = interface.address
            setsockopt(
                descriptor,
                IPPROTO_IP,
                IP_ADD_MEMBERSHIP,
                &request,
                socklen_t(MemoryLayout<ip_mreq>.size)
            )
        }
    }
}
