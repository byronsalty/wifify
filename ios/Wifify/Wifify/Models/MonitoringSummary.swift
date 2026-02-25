import Foundation

struct StatBlock: Codable {
    var avg: Double?
    var min: Double?
    var max: Double?
    var p95: Double?
    var p99: Double?
    var stddev: Double?
}

struct SignalStats: Codable {
    var avg: Double?
    var min: Int?
    var max: Int?
}

struct MonitoringSummary: Codable {
    var durationMin: Double
    var totalSamples: Int
    var gatewayTotal: Int
    var gatewayStats: StatBlock
    var gatewayLossCount: Int
    var gatewayAvgMs: Double?
    var gatewayP95Ms: Double?
    var gatewayJitterMs: Double?
    var internetStats: StatBlock
    var internetLossCount: Int
    var anomalyCount: Int
    var anomalyTimestamps: [String]
    var signalStats: SignalStats?

    enum CodingKeys: String, CodingKey {
        case durationMin = "duration_min"
        case totalSamples = "total_samples"
        case gatewayTotal = "gateway_total"
        case gatewayStats = "gateway_stats"
        case gatewayLossCount = "gateway_loss_count"
        case gatewayAvgMs = "gateway_avg_ms"
        case gatewayP95Ms = "gateway_p95_ms"
        case gatewayJitterMs = "gateway_jitter_ms"
        case internetStats = "internet_stats"
        case internetLossCount = "internet_loss_count"
        case anomalyCount = "anomaly_count"
        case anomalyTimestamps = "anomaly_timestamps"
        case signalStats = "signal_stats"
    }
}
