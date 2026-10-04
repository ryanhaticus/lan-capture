import Darwin
import Foundation

struct LocalNetworkAddress: Equatable {
    let address: String
    let interfaceName: String?

    var interfaceDescription: String {
        guard let interfaceName else { return "No active LAN interface found" }
        return "IPv4 on \(interfaceName)"
    }

    static func current() -> LocalNetworkAddress {
        allIPv4Addresses().sorted { rank($0) < rank($1) }.first
            ?? LocalNetworkAddress(address: "Unavailable", interfaceName: nil)
    }

    private static func allIPv4Addresses() -> [LocalNetworkAddress] {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return [] }
        defer { freeifaddrs(firstAddress) }

        var results: [LocalNetworkAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let interface = cursor?.pointee {
            defer { cursor = interface.ifa_next }
            guard let socketAddress = interface.ifa_addr,
                socketAddress.pointee.sa_family == UInt8(AF_INET),
                interface.ifa_flags & UInt32(IFF_UP) != 0,
                interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let address = String(cString: host)
            guard address != "0.0.0.0", !address.hasPrefix("169.254.") else { continue }
            results.append(
                LocalNetworkAddress(
                    address: address,
                    interfaceName: String(cString: interface.ifa_name)
                )
            )
        }
        return results
    }

    private static func rank(_ address: LocalNetworkAddress) -> Int {
        switch address.interfaceName {
        case "en0": 0
        case "en1": 1
        case let name? where name.hasPrefix("en"): 2
        case let name? where name.hasPrefix("bridge"): 3
        case let name? where name.hasPrefix("utun"): 9
        default: 5
        }
    }
}
