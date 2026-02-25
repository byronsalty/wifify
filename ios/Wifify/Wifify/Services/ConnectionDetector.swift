import Foundation
import Network

final class ConnectionDetector: Sendable {

    func detectConnection() async -> ConnectionInfo {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()

                let type: String
                let hwPort: String
                let interface: String?

                if path.usesInterfaceType(.wifi) {
                    type = "wifi"
                    hwPort = "Wi-Fi"
                    interface = path.availableInterfaces.first { $0.type == .wifi }?.name
                } else if path.usesInterfaceType(.wiredEthernet) {
                    type = "ethernet"
                    hwPort = "Ethernet"
                    interface = path.availableInterfaces.first { $0.type == .wiredEthernet }?.name
                } else if path.usesInterfaceType(.cellular) {
                    type = "cellular"
                    hwPort = "Cellular"
                    interface = path.availableInterfaces.first { $0.type == .cellular }?.name
                } else {
                    type = "unknown"
                    hwPort = "Unknown"
                    interface = nil
                }

                let gateway = Self.detectGateway(interface: interface)

                continuation.resume(returning: ConnectionInfo(
                    interface: interface,
                    type: type,
                    hardwarePort: hwPort,
                    gateway: gateway
                ))
            }
            monitor.start(queue: DispatchQueue.global(qos: .userInitiated))
        }
    }

    /// Heuristic gateway detection: find interface IP, assume gateway is x.x.x.1.
    /// Works for ~95% of home networks.
    private static func detectGateway(interface ifName: String?) -> String? {
        guard let ifName else { return nil }

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var current: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let ptr = current {
            let name = String(cString: ptr.pointee.ifa_name)
            if name == ifName,
               let addr = ptr.pointee.ifa_addr,
               addr.pointee.sa_family == sa_family_t(AF_INET) {
                let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                let ip = String(cString: inet_ntoa(sin.sin_addr))
                let parts = ip.split(separator: ".")
                if parts.count == 4 {
                    return "\(parts[0]).\(parts[1]).\(parts[2]).1"
                }
            }
            current = ptr.pointee.ifa_next
        }
        return nil
    }
}
