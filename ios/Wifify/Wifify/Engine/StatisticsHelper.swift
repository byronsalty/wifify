import Foundation

enum StatisticsHelper {

    static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    static func stddev(_ values: [Double]) -> Double? {
        guard values.count > 1, let avg = mean(values) else { return nil }
        let variance = values.reduce(0) { $0 + ($1 - avg) * ($1 - avg) } / Double(values.count - 1)
        return sqrt(variance)
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = p / 100.0 * Double(sorted.count - 1)
        let lower = Int(floor(index))
        let upper = Int(ceil(index))
        if lower == upper || upper >= sorted.count {
            return sorted[min(lower, sorted.count - 1)]
        }
        let fraction = index - Double(lower)
        return sorted[lower] + fraction * (sorted[upper] - sorted[lower])
    }

    static func jitter(_ rtts: [Double]) -> Double? {
        guard rtts.count > 1 else { return nil }
        var deltas: [Double] = []
        for i in 1..<rtts.count {
            deltas.append(abs(rtts[i] - rtts[i - 1]))
        }
        return mean(deltas)
    }

    static func computeStatBlock(from values: [Double]) -> StatBlock {
        StatBlock(
            avg: mean(values),
            min: values.min(),
            max: values.max(),
            p95: percentile(values, 95),
            p99: percentile(values, 99),
            stddev: stddev(values)
        )
    }

    static func buildMonitoringSummary(
        samples: [MonitoringSample],
        startTime: Date,
        anomalies: [MonitoringSample]
    ) -> MonitoringSummary {
        let durationMin = Date().timeIntervalSince(startTime) / 60.0

        let gwRtts = samples.compactMap(\.gatewayMs)
        let inetRtts = samples.compactMap(\.internetMs)
        let gwLoss = samples.filter { $0.gatewayMs == nil }.count
        let inetLoss = samples.filter { $0.internetMs == nil }.count
        let signalValues = samples.compactMap(\.signalDbm)

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        let anomalyTimestamps = anomalies.map { sample in
            formatter.string(from: Date(timeIntervalSince1970: sample.timestamp))
        }

        var signalStats: SignalStats? = nil
        if !signalValues.isEmpty {
            signalStats = SignalStats(
                avg: mean(signalValues.map { Double($0) }),
                min: signalValues.min(),
                max: signalValues.max()
            )
        }

        return MonitoringSummary(
            durationMin: round(durationMin * 10) / 10,
            totalSamples: samples.count,
            gatewayTotal: samples.count,
            gatewayStats: computeStatBlock(from: gwRtts),
            gatewayLossCount: gwLoss,
            gatewayAvgMs: mean(gwRtts),
            gatewayP95Ms: percentile(gwRtts, 95),
            gatewayJitterMs: jitter(gwRtts),
            internetStats: computeStatBlock(from: inetRtts),
            internetLossCount: inetLoss,
            anomalyCount: anomalies.count,
            anomalyTimestamps: anomalyTimestamps,
            signalStats: signalStats
        )
    }
}
