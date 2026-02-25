import Foundation

struct LocationInfo: Codable, Equatable {
    var city: String?
    var region: String?
    var country: String?
}

struct MetaInfo: Codable {
    var version: String
    var timestamp: String
    var timestampEpoch: Double
    var label: String
    var hostname: String
    var osVersion: String
    var durationMin: Double
    var platform: String?
    var publicIp: String?
    var location: LocationInfo?

    enum CodingKeys: String, CodingKey {
        case version, timestamp, label, hostname, platform, location
        case timestampEpoch = "timestamp_epoch"
        case osVersion = "os_version"
        case durationMin = "duration_min"
        case publicIp = "public_ip"
    }
}
