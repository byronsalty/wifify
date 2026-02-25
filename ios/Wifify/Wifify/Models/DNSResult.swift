import Foundation

struct DNSQuery: Codable {
    var domain: String
    var server: String
    var timeMs: Int?
    var status: String
    var answer: String?

    enum CodingKeys: String, CodingKey {
        case domain, server, status, answer
        case timeMs = "time_ms"
    }
}

struct DNSResult: Codable {
    var queries: [DNSQuery]
    var avgTimeMs: Double?
    var maxTimeMs: Int?
    var failures: Int

    enum CodingKeys: String, CodingKey {
        case queries, failures
        case avgTimeMs = "avg_time_ms"
        case maxTimeMs = "max_time_ms"
    }
}
