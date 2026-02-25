import Foundation

enum FirestoreService {

    // MARK: - Upload

    /// Upload a result to the community Firestore collection.
    static func upload(result: DiagnosticsResult, handle: String, network: String, isp: String?) async throws {
        guard FirebaseConfig.isConfigured else {
            throw FirestoreError.notConfigured
        }

        let token = try await FirebaseAuthService.anonymousAuth()
        let payload = extractUploadPayload(from: result)

        var fields: [String: Any] = [
            "handle": ["stringValue": handle],
            "network": ["stringValue": network],
            "platform": ["stringValue": payload.platform],
            "connection": ["stringValue": payload.connection],
            "os": ["stringValue": payload.os],
            "monitoring_duration_min": ["doubleValue": payload.monitoringDurationMin],
            "anomaly_count": ["integerValue": String(payload.anomalyCount)],
            "gateway_packet_loss_pct": ["doubleValue": payload.gatewayPacketLossPct],
            "internet_packet_loss_pct": ["doubleValue": payload.internetPacketLossPct],
        ]

        if let ts = payload.clientTimestamp { fields["client_timestamp"] = ["stringValue": ts] }
        if let v = payload.publicIp { fields["public_ip"] = ["stringValue": v] }
        if let v = payload.city { fields["city"] = ["stringValue": v] }
        if let v = payload.region { fields["region"] = ["stringValue": v] }
        if let v = payload.country { fields["country"] = ["stringValue": v] }
        if let v = payload.downloadMbps { fields["download_mbps"] = ["doubleValue": v] }
        if let v = payload.uploadMbps { fields["upload_mbps"] = ["doubleValue": v] }
        if let v = payload.rpm { fields["rpm"] = ["integerValue": String(v)] }
        if let v = payload.bufferbloatRatio { fields["bufferbloat_ratio"] = ["doubleValue": v] }
        if let v = payload.gatewayLatencyAvg { fields["gateway_latency_avg"] = ["doubleValue": v] }
        if let v = payload.gatewayLatencyP95 { fields["gateway_latency_p95"] = ["doubleValue": v] }
        if let v = payload.internetLatencyAvg { fields["internet_latency_avg"] = ["doubleValue": v] }
        if let v = payload.dnsAvgMs { fields["dns_avg_ms"] = ["doubleValue": v] }
        if let v = payload.rssi { fields["rssi"] = ["integerValue": String(v)] }
        if let v = payload.snr { fields["snr"] = ["integerValue": String(v)] }
        if let v = payload.channelBand { fields["channel_band"] = ["stringValue": v] }
        if let v = isp { fields["isp"] = ["stringValue": v] }

        let body: [String: Any] = ["fields": fields]
        let jsonData = try JSONSerialization.data(withJSONObject: body)

        let urlString = "\(FirebaseConfig.firestoreBaseURL)/results"
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = jsonData

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw FirestoreError.uploadFailed
        }
    }

    // MARK: - Leaderboard

    struct LeaderboardEntry {
        let handle: String
        let value: Double
        let os: String
        let isp: String?
        let date: String
    }

    static func fetchLeaderboard(
        network: String, connection: String, metricField: String, limit: Int = 20
    ) async throws -> [LeaderboardEntry] {
        guard FirebaseConfig.isConfigured else { throw FirestoreError.notConfigured }

        // Firestore structured query via REST
        let queryBody: [String: Any] = [
            "structuredQuery": [
                "from": [["collectionId": "results"]],
                "where": [
                    "compositeFilter": [
                        "op": "AND",
                        "filters": [
                            ["fieldFilter": ["field": ["fieldPath": "network"], "op": "EQUAL", "value": ["stringValue": network]]],
                            ["fieldFilter": ["field": ["fieldPath": "connection"], "op": "EQUAL", "value": ["stringValue": connection]]],
                        ]
                    ]
                ],
                "orderBy": [["field": ["fieldPath": metricField], "direction": "DESCENDING"]],
                "limit": limit
            ]
        ]

        let urlString = "\(FirebaseConfig.firestoreBaseURL):runQuery"
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: queryBody)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let results = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return results.compactMap { doc -> LeaderboardEntry? in
            guard let document = doc["document"] as? [String: Any],
                  let fields = document["fields"] as? [String: [String: Any]] else { return nil }

            let handle = fields["handle"]?["stringValue"] as? String ?? "?"
            let os = fields["os"]?["stringValue"] as? String ?? "?"
            let isp = fields["isp"]?["stringValue"] as? String
            let date = fields["client_timestamp"]?["stringValue"] as? String ?? ""

            var value: Double?
            if let dv = fields[metricField]?["doubleValue"] as? Double {
                value = dv
            } else if let iv = fields[metricField]?["integerValue"] as? String {
                value = Double(iv)
            }

            guard let v = value else { return nil }
            return LeaderboardEntry(handle: handle, value: v, os: os, isp: isp, date: String(date.prefix(10)))
        }
    }

    // MARK: - Helpers

    private struct UploadPayload {
        let clientTimestamp: String?
        let platform: String
        let connection: String
        let os: String
        let publicIp: String?
        let city: String?
        let region: String?
        let country: String?
        let downloadMbps: Double?
        let uploadMbps: Double?
        let rpm: Int?
        let bufferbloatRatio: Double?
        let gatewayLatencyAvg: Double?
        let gatewayLatencyP95: Double?
        let gatewayPacketLossPct: Double
        let internetLatencyAvg: Double?
        let internetPacketLossPct: Double
        let dnsAvgMs: Double?
        let monitoringDurationMin: Double
        let anomalyCount: Int
        let rssi: Int?
        let snr: Int?
        let channelBand: String?
    }

    /// Extract curated fields for upload — matches extract_upload_payload() in wifify.py.
    private static func extractUploadPayload(from result: DiagnosticsResult) -> UploadPayload {
        let conn = result.connection.type == "wifi" ? "wifi" : "wired"
        let summary = result.monitoringSummary
        let inetLossPct: Double = summary.gatewayTotal > 0
            ? Double(summary.internetLossCount) / Double(summary.gatewayTotal) * 100
            : 0
        let gwLossPct: Double = summary.gatewayTotal > 0
            ? Double(summary.gatewayLossCount) / Double(summary.gatewayTotal) * 100
            : 0

        return UploadPayload(
            clientTimestamp: result.meta.timestamp,
            platform: result.meta.platform ?? "ios",
            connection: conn,
            os: result.meta.osVersion,
            publicIp: result.meta.publicIp,
            city: result.meta.location?.city,
            region: result.meta.location?.region,
            country: result.meta.location?.country,
            downloadMbps: result.speed.dlThroughputMbps,
            uploadMbps: result.speed.ulThroughputMbps,
            rpm: result.speed.responsivenessRpm,
            bufferbloatRatio: result.speed.bufferbloatRatio,
            gatewayLatencyAvg: summary.gatewayAvgMs,
            gatewayLatencyP95: summary.gatewayP95Ms,
            gatewayPacketLossPct: gwLossPct,
            internetLatencyAvg: summary.internetStats.avg,
            internetPacketLossPct: inetLossPct,
            dnsAvgMs: result.dns.avgTimeMs,
            monitoringDurationMin: summary.durationMin,
            anomalyCount: summary.anomalyCount,
            rssi: result.wifiSignal?.rssiDbm,
            snr: result.wifiSignal?.snrDb,
            channelBand: result.wifiSignal?.channelBand
        )
    }

    enum FirestoreError: LocalizedError {
        case notConfigured
        case uploadFailed

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Firebase is not configured. Set project ID and API key in FirebaseConfig.swift."
            case .uploadFailed: return "Failed to upload results to Firebase."
            }
        }
    }
}
