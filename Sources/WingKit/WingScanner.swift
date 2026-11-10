import ConsoleSockets
import Foundation

/// Asks every WING on the network to identify itself, so the user can choose
/// one. It only broadcasts `WING?` from its own socket and never connects, so
/// it does not disturb a running session. Every method must be called on the
/// queue given at creation, where the handler runs too.
public final class WingScanner {
    private let queue: DispatchQueue
    private let onConsole: (WingConsoleInfo) -> Void
    private var socket: ConsoleUDPSocket?

    public init(queue: DispatchQueue, onConsole: @escaping (WingConsoleInfo) -> Void) {
        self.queue = queue
        self.onConsole = onConsole
    }

    deinit { socket?.close() }

    /// Sends one discovery request. A socket that could not be opened is tried
    /// again on the next request.
    public func probe() {
        if socket == nil {
            socket = ConsoleUDPSocket(queue: queue) { [weak self] datagram, _ in
                self?.handle(datagram)
            }
        }
        socket?.broadcast(WingProtocol.discoveryRequest, port: WingProtocol.port)
    }

    public func stop() {
        socket?.close()
        socket = nil
    }

    private func handle(_ datagram: [UInt8]) {
        guard datagram.starts(with: WingProtocol.discoveryReplyPrefix),
              let info = WingConsoleInfo(
                  discoveryReply: String(decoding: datagram, as: UTF8.self)
              ) else { return }
        onConsole(info)
    }
}
