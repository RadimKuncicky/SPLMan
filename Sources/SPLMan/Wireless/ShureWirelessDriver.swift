import Foundation
import ShureKit

/// Adapts `ShureClient` to the application's generic wireless layer.
final class ShureWirelessDriver: WirelessDriver {
    private var client: ShureClient?

    func start(address: String) {
        stop()
        let client = ShureClient(address: address)
        self.client = client
        client.start()
    }

    func poll() -> WirelessDriverUpdate {
        guard let client else { return WirelessDriverUpdate(state: .failed) }
        let snapshot = client.snapshot()
        let state: WirelessDriverState
        switch snapshot.state {
        case .connecting: state = .connecting
        case .connected: state = .connected
        case .unsupported: state = .unsupported
        case .failed: state = .failed
        }
        return WirelessDriverUpdate(
            state: state,
            model: snapshot.modelName,
            deviceName: snapshot.deviceID,
            secondsSinceData: snapshot.secondsSinceData,
            channels: snapshot.channels.map { channel in
                WirelessChannelReading(
                    number: channel.number,
                    name: channel.name,
                    audioLevelDB: channel.audioLevelDBFS,
                    rfLevelDBm: channel.rfLevelDBm,
                    batteryBars: channel.batteryBars,
                    batteryMinutes: channel.batteryMinutes,
                    transmitterModel: channel.transmitterModel
                )
            }
        )
    }

    func stop() {
        client?.stop()
        client = nil
    }
}
