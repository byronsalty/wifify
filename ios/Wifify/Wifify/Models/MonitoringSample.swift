import Foundation

struct MonitoringSample: Codable {
    var timestamp: Double
    var anomaly: Bool
    var gatewayMs: Double?
    var internetMs: Double?
    var signalDbm: Int?
    var noiseDbm: Int?

    enum CodingKeys: String, CodingKey {
        case timestamp, anomaly
        case gatewayMs = "gateway_ms"
        case internetMs = "internet_ms"
        case signalDbm = "signal_dbm"
        case noiseDbm = "noise_dbm"
    }
}
