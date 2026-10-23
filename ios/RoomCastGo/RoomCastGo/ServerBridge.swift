import Foundation
import Roomcast

/// gobind writes C functions into Roomcast.objc.h, not throwing methods.
/// Start is `BOOL RoomcastStart(long, long, NSString*, NSString*, NSString*, NSError**)`.
/// Swift leaves the error pointer as a real argument. Go `int` is `long`
/// (Swift `Int`). Go `[]byte` is `NSData*`, which `Data` bridges to.
enum BroadcastServer {
    static func start(ip: String, iface: String) throws {
        var error: NSError?
        let started = RoomcastStart(
            BroadcastPorts.http,
            BroadcastPorts.ice,
            ip,
            iface,
            BroadcastPorts.title,
            &error
        )
        if !started {
            throw error ?? NSError(
                domain: "Roomcast",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The broadcast server did not start."]
            )
        }
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
