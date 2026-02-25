import Foundation

struct WiFiSignalInfo: Codable {
    var rssiDbm: Int?
    var noiseDbm: Int?
    var snrDb: Int?
    var channel: String?
    var channelBand: String?
    var channelWidth: String?
    var txRateMbps: Double?
    var mcsIndex: Int?
    var phyMode: String?
    var ssid: String?
    var bssid: String?
    var security: String?
    var signalStrengthNormalized: Double?

    enum CodingKeys: String, CodingKey {
        case ssid, bssid, channel, security
        case rssiDbm = "rssi_dbm"
        case noiseDbm = "noise_dbm"
        case snrDb = "snr_db"
        case channelBand = "channel_band"
        case channelWidth = "channel_width"
        case txRateMbps = "tx_rate_mbps"
        case mcsIndex = "mcs_index"
        case phyMode = "phy_mode"
        case signalStrengthNormalized = "signal_strength_normalized"
    }
}
