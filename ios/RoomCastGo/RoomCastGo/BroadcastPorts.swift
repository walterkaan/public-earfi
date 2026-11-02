import Foundation

enum SessionName {
    static let key = "broadcast.sessionName"
    static let fallback = "RoomCast Broadcast"
    static let limit = 80

    static var stored: String {
        cleaned(UserDefaults.standard.string(forKey: key) ?? "")
    }

    static func cleaned(_ raw: String) -> String {
        let kept = raw.unicodeScalars.filter { scalar in
            let value = scalar.value
            return value >= 32 && value != 127
        }
        let collapsed = String(String.UnicodeScalarView(kept))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        if trimmed.count <= limit { return trimmed }
        let cut = String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
        return cut.isEmpty ? fallback : cut
    }
}

enum BroadcastPorts {
    /// Listener page and WHEP. Same port the Mac app shows on the poster.
    static let http = 8889
    /// Shared UDP and TCP port for WebRTC media.
    static let ice = 8189
}
