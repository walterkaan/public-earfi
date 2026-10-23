enum BroadcastPorts {
    /// Listener page and WHEP. Same port the Mac app shows on the poster.
    static let http = 8889
    /// Shared UDP and TCP port for WebRTC media.
    static let ice = 8189
    static let title = "RoomCast Broadcast"
}
