import Foundation

/// Top-level result container matching the CLI JSON schema exactly.
struct DiagnosticsResult: Codable {
    var meta: MetaInfo
    var connection: ConnectionInfo
    var wifiSignal: WiFiSignalInfo?
    var baselineLatency: [String: PingResult]
    var dns: DNSResult
    var traceroute: TracerouteResult
    var speed: SpeedResult
    var monitoring: [MonitoringSample]
    var monitoringSummary: MonitoringSummary
    var verdicts: [Verdict]

    enum CodingKeys: String, CodingKey {
        case meta, connection, dns, traceroute, speed, monitoring, verdicts
        case wifiSignal = "wifi_signal"
        case baselineLatency = "baseline_latency"
        case monitoringSummary = "monitoring_summary"
    }
}
