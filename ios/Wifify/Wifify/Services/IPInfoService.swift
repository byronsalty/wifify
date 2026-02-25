import Foundation

/// Fetches public IP and approximate location via ipinfo.io (free, no key required).
enum IPInfoService {

    struct IPInfo {
        let publicIp: String?
        let city: String?
        let region: String?
        let country: String?
    }

    static func fetch() async -> IPInfo {
        do {
            var request = URLRequest(url: URL(string: "https://ipinfo.io/json")!)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("wifify-ios/1.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 5

            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

            return IPInfo(
                publicIp: json["ip"] as? String,
                city: json["city"] as? String,
                region: json["region"] as? String,
                country: json["country"] as? String
            )
        } catch {
            return IPInfo(publicIp: nil, city: nil, region: nil, country: nil)
        }
    }
}
