import Foundation

struct TracerouteHop: Codable {
    var hop: Int
    var host: String?
    var ip: String?
    var rttsMs: [Double]

    enum CodingKeys: String, CodingKey {
        case hop, host, ip
        case rttsMs = "rtts_ms"
    }
}

struct TracerouteResult: Codable {
    var target: String
    var hops: [TracerouteHop]
    var totalHops: Int
    var error: String?

    enum CodingKeys: String, CodingKey {
        case target, hops, error
        case totalHops = "total_hops"
    }

    static func unavailable() -> TracerouteResult {
        TracerouteResult(
            target: "8.8.8.8",
            hops: [],
            totalHops: 0,
            error: "Traceroute not available on iOS"
        )
    }
}
