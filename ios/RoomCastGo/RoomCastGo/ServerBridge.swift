import Foundation
import Roomcast

/// gobind writes C functions into Roomcast.objc.h, not throwing methods.
/// Start is `BOOL RoomcastStart(long, long, NSString*, NSString*, NSString*, NSError**)`.
/// Swift leaves the error pointer as a real argument. Go `int` is `long`
/// (Swift `Int`). Go `[]byte` is `NSData*`, which `Data` bridges to.
///
/// These calls block. Stop can sit in `http.Server.Shutdown` for about two
/// seconds. They are plain functions, so `BroadcastServerGate` runs them
/// off the main actor. `publish` stays on the audio thread.
enum BroadcastServer {
    static func start(ip: String, iface: String) -> String? {
        var error: NSError?
        let started = RoomcastStart(
            BroadcastPorts.http,
            BroadcastPorts.ice,
            ip,
            iface,
            BroadcastPorts.title,
            &error
        )
        if started { return nil }
        return error?.localizedDescription ?? "The broadcast server did not start."
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

/// Serializes every gomobile call except `publish`, and keeps them off
/// the main actor. Start and stop cannot overlap.
actor BroadcastServerGate {
    func start(ip: String, iface: String) -> String? {
        BroadcastServer.start(ip: ip, iface: iface)
    }

    func stop() {
        BroadcastServer.stop()
    }

    func listenerCount() -> Int {
        BroadcastServer.listenerCount()
    }

    func selectHost(_ table: String) -> String {
        BroadcastServer.selectHost(table)
    }
}
