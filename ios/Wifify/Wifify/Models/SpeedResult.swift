import Foundation

struct SpeedResult: Codable {
    var dlThroughputMbps: Double?
    var ulThroughputMbps: Double?
    var responsivenessRpm: Int?
    var baseRttMs: Double?
    var idleLatencyMs: Double?
    var loadedLatencyMs: Double?
    var bufferbloatMs: Double?
    var bufferbloatRatio: Double?
    var interfaceName: String?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case error
        case dlThroughputMbps = "dl_throughput_mbps"
        case ulThroughputMbps = "ul_throughput_mbps"
        case responsivenessRpm = "responsiveness_rpm"
        case baseRttMs = "base_rtt_ms"
        case idleLatencyMs = "idle_latency_ms"
        case loadedLatencyMs = "loaded_latency_ms"
        case bufferbloatMs = "bufferbloat_ms"
        case bufferbloatRatio = "bufferbloat_ratio"
        case interfaceName = "interface_name"
    }
}
