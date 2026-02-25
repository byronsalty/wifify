import Foundation

protocol DNSServiceProtocol: Sendable {
    func testDNSResolution() async -> DNSResult
}

final class DNSService: DNSServiceProtocol {
    private let testDomains = ["google.com", "apple.com", "amazon.com", "github.com", "cloudflare.com"]
    private let dnsServers: [String?] = [nil, "8.8.8.8", "1.1.1.1"]

    func testDNSResolution() async -> DNSResult {
        var queries: [DNSQuery] = []

        for domain in testDomains {
            for server in dnsServers {
                let serverLabel = server ?? "system"
                let start = CFAbsoluteTimeGetCurrent()

                if let server {
                    // Custom DNS server: build raw UDP query
                    let result = await resolveViaUDP(domain: domain, server: server)
                    let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                    queries.append(DNSQuery(
                        domain: domain, server: serverLabel,
                        timeMs: result.success ? elapsed : nil,
                        status: result.success ? "ok" : "fail",
                        answer: result.address
                    ))
                } else {
                    // System DNS: use getaddrinfo
                    let result = await resolveSystem(domain: domain)
                    let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                    queries.append(DNSQuery(
                        domain: domain, server: serverLabel,
                        timeMs: result.success ? elapsed : nil,
                        status: result.success ? "ok" : "fail",
                        answer: result.address
                    ))
                }
            }
        }

        let okTimes = queries.compactMap(\.timeMs)
        return DNSResult(
            queries: queries,
            avgTimeMs: okTimes.isEmpty ? nil : Double(okTimes.reduce(0, +)) / Double(okTimes.count),
            maxTimeMs: okTimes.max(),
            failures: queries.filter { $0.status == "fail" }.count
        )
    }

    /// Resolve using the system DNS (getaddrinfo).
    private func resolveSystem(domain: String) async -> (success: Bool, address: String?) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = SOCK_STREAM

                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(domain, nil, &hints, &result)
                defer { if result != nil { freeaddrinfo(result) } }

                if status == 0, let addrInfo = result {
                    let addr = addrInfo.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        $0.pointee
                    }
                    let ip = String(cString: inet_ntoa(addr.sin_addr))
                    continuation.resume(returning: (true, ip))
                } else {
                    continuation.resume(returning: (false, nil))
                }
            }
        }
    }

    /// Resolve by sending a raw DNS query via UDP to a specific server.
    private func resolveViaUDP(domain: String, server: String) async -> (success: Bool, address: String?) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
                guard fd >= 0 else {
                    continuation.resume(returning: (false, nil))
                    return
                }
                defer { close(fd) }

                // Set timeout
                var tv = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                // Server address
                var serverAddr = sockaddr_in()
                serverAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                serverAddr.sin_family = sa_family_t(AF_INET)
                serverAddr.sin_port = UInt16(53).bigEndian
                inet_pton(AF_INET, server, &serverAddr.sin_addr)

                // Build DNS query packet
                let query = Self.buildDNSQuery(domain: domain)

                // Send
                let sent = withUnsafePointer(to: &serverAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(fd, (query as NSData).bytes, query.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard sent > 0 else {
                    continuation.resume(returning: (false, nil))
                    return
                }

                // Receive
                var buffer = [UInt8](repeating: 0, count: 512)
                let received = recv(fd, &buffer, buffer.count, 0)
                guard received > 12 else {
                    continuation.resume(returning: (false, nil))
                    return
                }

                // Parse response for A record
                if let ip = Self.parseDNSResponse(Data(buffer[0..<received])) {
                    continuation.resume(returning: (true, ip))
                } else {
                    continuation.resume(returning: (false, nil))
                }
            }
        }
    }

    /// Build a minimal DNS A-record query packet.
    private static func buildDNSQuery(domain: String) -> Data {
        var packet = Data()

        // Header: ID(2) + Flags(2) + Questions(2) + Answers(2) + Auth(2) + Additional(2)
        let id = UInt16.random(in: 1...0xFFFF)
        packet.append(contentsOf: withUnsafeBytes(of: id.bigEndian) { Array($0) })
        packet.append(contentsOf: [0x01, 0x00]) // Flags: standard query, recursion desired
        packet.append(contentsOf: [0x00, 0x01]) // Questions: 1
        packet.append(contentsOf: [0x00, 0x00]) // Answers: 0
        packet.append(contentsOf: [0x00, 0x00]) // Authority: 0
        packet.append(contentsOf: [0x00, 0x00]) // Additional: 0

        // Question: domain name in DNS wire format
        for label in domain.split(separator: ".") {
            packet.append(UInt8(label.count))
            packet.append(contentsOf: label.utf8)
        }
        packet.append(0x00) // End of name

        packet.append(contentsOf: [0x00, 0x01]) // Type: A
        packet.append(contentsOf: [0x00, 0x01]) // Class: IN

        return packet
    }

    /// Parse a DNS response to extract the first A record IP.
    private static func parseDNSResponse(_ data: Data) -> String? {
        guard data.count > 12 else { return nil }

        let answerCount = (UInt16(data[6]) << 8) | UInt16(data[7])
        guard answerCount > 0 else { return nil }

        // Skip past the question section
        var offset = 12
        // Skip QNAME
        while offset < data.count {
            let len = Int(data[offset])
            if len == 0 { offset += 1; break }
            if len >= 0xC0 { offset += 2; break } // Pointer
            offset += 1 + len
        }
        offset += 4 // Skip QTYPE + QCLASS

        // Parse answer records
        for _ in 0..<answerCount {
            guard offset + 12 <= data.count else { return nil }

            // Skip name (may be pointer)
            if data[offset] >= 0xC0 {
                offset += 2
            } else {
                while offset < data.count && data[offset] != 0 { offset += 1 + Int(data[offset]) }
                offset += 1
            }

            guard offset + 10 <= data.count else { return nil }
            let rtype = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
            let rdlength = Int((UInt16(data[offset + 8]) << 8) | UInt16(data[offset + 9]))
            offset += 10

            if rtype == 1 && rdlength == 4 && offset + 4 <= data.count {
                // A record — 4 bytes IPv4
                return "\(data[offset]).\(data[offset+1]).\(data[offset+2]).\(data[offset+3])"
            }
            offset += rdlength
        }
        return nil
    }
}
