import Darwin
import Foundation

struct HostInterface: Equatable {
    var name: String
    var address: String
}

enum HostAddress {
    /// One line per interface, "name address", for RoomcastSelectHost.
    static func table() -> String {
        interfaces().map { "\($0.name) \($0.address)" }.joined(separator: "\n")
    }

    static func interfaces() -> [HostInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(first) }

        var found: [HostInterface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let next = current.pointee.ifa_next
            let flags = Int32(current.pointee.ifa_flags)
            if (flags & IFF_UP) != 0, let addr = current.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let length = socklen_t(addr.pointee.sa_len)
                if getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    found.append(HostInterface(
                        name: String(cString: current.pointee.ifa_name),
                        address: String(cString: host)
                    ))
                }
            }
            cursor = next
        }
        return found
    }
}
