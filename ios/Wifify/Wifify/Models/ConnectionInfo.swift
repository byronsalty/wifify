import Foundation

struct ConnectionInfo: Codable {
    var interface: String?
    var type: String
    var hardwarePort: String
    var gateway: String?

    enum CodingKeys: String, CodingKey {
        case interface, type, gateway
        case hardwarePort = "hardware_port"
    }
}
