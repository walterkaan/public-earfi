import Foundation
import Roomcast

/// gobind writes C functions into Roomcast.objc.h, not throwing methods.
/// Start is `BOOL RoomcastStart(long, long, NSString*, NSString*, NSString*, NSString*, int64_t, NSError**)`.
/// The extra strings are the session title and the "from" device name.
/// `startedUnix` is the broadcast clock in unix seconds.
/// Swift leaves the error pointer as a real argument. Go `int` is `long`
/// (Swift `Int`). Go `int64` is `int64_t` (Swift `Int64`). Go `[]byte` is
/// `NSData*`, which `Data` bridges to.
///
/// Rebuild `Roomcast.xcframework` after this signature changes. The listener
/// page is compiled into that framework.
///
/// These calls block. Stop can sit in `http.Server.Shutdown` for about two
/// seconds. They are plain functions, so `BroadcastServerGate` runs them
/// off the main actor. `publish` stays on the audio thread.
enum BroadcastServer {
    static func start(ip: String, iface: String, title: String, host: String, started: Date) -> String? {
        var error: NSError?
        let unix = Int64(started.timeIntervalSince1970.rounded())
        let startedOK = RoomcastStart(
            BroadcastPorts.http,
            BroadcastPorts.ice,
            ip,
            iface,
            title,
            host,
            unix,
            &error
        )
        if startedOK { return nil }
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
    func start(ip: String, iface: String, title: String, host: String, started: Date) -> String? {
        BroadcastServer.start(ip: ip, iface: iface, title: title, host: host, started: started)
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
