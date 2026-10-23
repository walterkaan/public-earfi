import Foundation
import Network

/// iOS shows the Local Network prompt when the app sends a packet to another
/// address on the LAN. Binding our own port is not enough, and a Bonjour
/// browse would need the multicast entitlement. A single UDP packet to a
/// neighbour on the same subnet is enough to ask.
final class LocalNetworkProbe {
    private var connection: NWConnection?

    func poke(ip: String) {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return }
        var host = parts
        host[3] = host[3] == 1 ? 2 : 1
        let target = host.map(String.init).joined(separator: ".")
        let connection = NWConnection(host: NWEndpoint.Host(target), port: 9, using: .udp)
        self.connection = connection
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: Data([0]), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        connection.start(queue: .global(qos: .utility))
    }
}
