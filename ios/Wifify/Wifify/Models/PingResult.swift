import Foundation

struct PingResult: Codable {
    var target: String
    var label: String
    var count: Int
    var transmitted: Int
    var received: Int
    var packetLossPct: Double
    var minMs: Double?
    var avgMs: Double?
    var maxMs: Double?
    var stddevMs: Double?
    var jitterMs: Double?
    var rttsMs: [Double]
    var error: String?

    enum CodingKeys: String, CodingKey {
        case target, label, count, transmitted, received, error
        case packetLossPct = "packet_loss_pct"
        case minMs = "min_ms"
        case avgMs = "avg_ms"
        case maxMs = "max_ms"
        case stddevMs = "stddev_ms"
        case jitterMs = "jitter_ms"
        case rttsMs = "rtts_ms"
    }
}
