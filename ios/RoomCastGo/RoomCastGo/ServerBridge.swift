import Foundation
import Roomcast

/// Names match the header gomobile writes inside Roomcast.xcframework
/// (`Headers/Roomcast.objc.h`): RoomcastStart, RoomcastStop,
/// RoomcastPublishOpus, RoomcastListenerCount, RoomcastSelectHost.
enum BroadcastServer {
    static func start(ip: String, iface: String) throws {
        try RoomcastStart(BroadcastPorts.http, BroadcastPorts.ice, ip, iface, BroadcastPorts.title)
    }

    static func stop() {
        RoomcastStop()
    }

    static func publish(_ packet: Data) {
        RoomcastPublishOpus(packet)
    }

    static func listenerCount() -> Int {
        RoomcastListenerCount()
    }

    static func selectHost(_ table: String) -> String {
        RoomcastSelectHost(table)
    }
}
