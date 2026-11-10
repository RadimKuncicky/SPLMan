import ConsoleSockets
import Foundation

/// Asks every X32 and M32 on the network to identify itself, so the user can
/// choose one. It only broadcasts the read-only `/xinfo` request from its own
/// socket and subscribes to nothing, so it does not disturb a running session.
/// Every method must be called on the queue given at creation, where the
/// handler runs too.
public final class X32Scanner {
    private let queue: DispatchQueue
    private let onConsole: (_ info: X32ConsoleInfo, _ sender: String) -> Void
    private var socket: ConsoleUDPSocket?

    public init(
        queue: DispatchQueue,
        onConsole: @escaping (_ info: X32ConsoleInfo, _ sender: String) -> Void
    ) {
        self.queue = queue
        self.onConsole = onConsole
    }

    deinit { socket?.close() }

    /// Sends one request. A socket that could not be opened is tried again on
    /// the next request.
    public func probe() {
        if socket == nil {
            socket = ConsoleUDPSocket(queue: queue) { [weak self] datagram, sender in
                self?.handle(datagram, from: sender)
            }
        }
        socket?.broadcast(X32Protocol.xinfoRequest, port: X32Protocol.port)
    }

    public func stop() {
        socket?.close()
        socket = nil
    }

    private func handle(_ datagram: [UInt8], from sender: in_addr) {
        guard let message = X32Message(packet: datagram),
              let info = X32ConsoleInfo(message: message) else { return }
        onConsole(info, ConsoleUDPSocket.text(of: sender))
    }
}
