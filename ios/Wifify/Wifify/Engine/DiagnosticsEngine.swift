import Foundation
import SwiftUI

/// Orchestrates the three diagnostic phases and exposes state for SwiftUI views.
@Observable
final class DiagnosticsEngine {

    enum Phase: Equatable {
        case idle
        case baseline(step: String)
        case monitoring(elapsed: TimeInterval, total: TimeInterval)
        case summary
        case complete
        case error(String)
    }

    // Observable state
    var phase: Phase = .idle
    var result: DiagnosticsResult?
    var recentSamples: [MonitoringSample] = []
    var currentSample: MonitoringSample?
    var baselineProgress: Double = 0
    var monitoringProgress: Double = 0

    // Configuration
    var label: String = ""
    var durationMinutes: Double = 15

    // Services
    private let pingService: PingServiceProtocol
    private let dnsService: DNSServiceProtocol
    private let speedTestService: SpeedTestServiceProtocol
    private let wifiService: WiFiServiceProtocol
    private let connectionDetector: ConnectionDetector

    private var runTask: Task<Void, Never>?

    init(
        pingService: PingServiceProtocol = PingService(),
        dnsService: DNSServiceProtocol = DNSService(),
        speedTestService: SpeedTestServiceProtocol = SpeedTestService(),
        wifiService: WiFiServiceProtocol = WiFiService(),
        connectionDetector: ConnectionDetector = ConnectionDetector()
    ) {
        self.pingService = pingService
        self.dnsService = dnsService
        self.speedTestService = speedTestService
        self.wifiService = wifiService
        self.connectionDetector = connectionDetector
    }

    func run() {
        runTask = Task { @MainActor in
            await performRun()
        }
    }

    func cancel() {
        runTask?.cancel()
    }

    @MainActor
    private func performRun() async {
        let startTime = Date()

        // Phase 1: Baseline
        phase = .baseline(step: "Detecting connection...")
        let connection = await connectionDetector.detectConnection()
        let autoLabel = label.isEmpty ? connection.type : label

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var diagnostics = DiagnosticsResult(
            meta: MetaInfo(
                version: "1.0.0",
                timestamp: isoFormatter.string(from: startTime),
                timestampEpoch: startTime.timeIntervalSince1970,
                label: autoLabel,
                hostname: ProcessInfo.processInfo.hostName,
                osVersion: "iOS \(UIDevice.current.systemVersion)",
                durationMin: durationMinutes,
                platform: "ios"
            ),
            connection: connection,
            wifiSignal: nil,
            baselineLatency: [:],
            dns: DNSResult(queries: [], avgTimeMs: nil, maxTimeMs: nil, failures: 0),
            traceroute: TracerouteResult.unavailable(),
            speed: SpeedResult(dlThroughputMbps: nil, ulThroughputMbps: nil, responsivenessRpm: nil,
                               baseRttMs: nil, idleLatencyMs: nil, loadedLatencyMs: nil,
                               bufferbloatMs: nil, bufferbloatRatio: nil, interfaceName: nil, error: nil),
            monitoring: [],
            monitoringSummary: MonitoringSummary(
                durationMin: 0, totalSamples: 0, gatewayTotal: 0,
                gatewayStats: StatBlock(avg: nil, min: nil, max: nil, p95: nil, p99: nil, stddev: nil),
                gatewayLossCount: 0, gatewayAvgMs: nil, gatewayP95Ms: nil, gatewayJitterMs: nil,
                internetStats: StatBlock(avg: nil, min: nil, max: nil, p95: nil, p99: nil, stddev: nil),
                internetLossCount: 0, anomalyCount: 0, anomalyTimestamps: [], signalStats: nil
            ),
            verdicts: []
        )

        // Public IP & location (runs concurrently with WiFi scan)
        phase = .baseline(step: "Fetching IP info...")
        let ipInfo = await IPInfoService.fetch()
        diagnostics.meta.publicIp = ipInfo.publicIp
        if ipInfo.city != nil || ipInfo.region != nil || ipInfo.country != nil {
            diagnostics.meta.location = LocationInfo(
                city: ipInfo.city, region: ipInfo.region, country: ipInfo.country
            )
        }

        // WiFi signal
        if connection.type == "wifi" {
            phase = .baseline(step: "Scanning WiFi signal...")
            diagnostics.wifiSignal = await wifiService.fetchCurrentNetwork()
        }

        // Baseline pings
        let targets: [(label: String, target: String)] = [
            ("gateway", connection.gateway ?? ""),
            ("dns_google", "8.8.8.8"),
            ("dns_cloudflare", "1.1.1.1"),
            ("google", "google.com"),
            ("apple", "apple.com"),
        ].filter { !$0.target.isEmpty }

        for (i, entry) in targets.enumerated() {
            guard !Task.isCancelled else { break }
            phase = .baseline(step: "Pinging \(entry.label)...")
            baselineProgress = Double(i) / Double(targets.count + 3)
            var pingResult = await pingService.ping(target: entry.target, count: 20)
            pingResult.label = entry.label
            diagnostics.baselineLatency[entry.label] = pingResult
        }

        // DNS
        guard !Task.isCancelled else { return savePartial(diagnostics) }
        phase = .baseline(step: "Testing DNS resolution...")
        baselineProgress = Double(targets.count) / Double(targets.count + 3)
        diagnostics.dns = await dnsService.testDNSResolution()

        // Speed test
        guard !Task.isCancelled else { return savePartial(diagnostics) }
        phase = .baseline(step: "Running speed test...")
        baselineProgress = Double(targets.count + 1) / Double(targets.count + 3)
        diagnostics.speed = await speedTestService.runSpeedTest(
            pingService: pingService, gateway: connection.gateway
        )
        baselineProgress = 1.0

        // Phase 2: Monitoring
        guard !Task.isCancelled else { return savePartial(diagnostics) }
        let monitoringResult = await runMonitoring(connection: connection, baselineResult: diagnostics)
        diagnostics.monitoring = monitoringResult.samples
        diagnostics.monitoringSummary = monitoringResult.summary

        // Phase 3: Summary
        phase = .summary
        diagnostics.verdicts = VerdictGenerator.generate(from: diagnostics)
        self.result = diagnostics
        phase = .complete
    }

    @MainActor
    private func runMonitoring(
        connection: ConnectionInfo,
        baselineResult: DiagnosticsResult
    ) async -> (samples: [MonitoringSample], summary: MonitoringSummary) {
        let durationSec = durationMinutes * 60
        let monitorStart = Date()
        var samples: [MonitoringSample] = []
        var anomalies: [MonitoringSample] = []
        var gwRtts: [Double] = []
        var lastSignalTime = Date.distantPast

        let baselineGwAvg = baselineResult.baselineLatency["gateway"]?.avgMs ?? 10.0
        var nextCycle = monitorStart.timeIntervalSince1970 + 5.0

        while Date().timeIntervalSince(monitorStart) < durationSec {
            guard !Task.isCancelled else { break }

            let elapsed = Date().timeIntervalSince(monitorStart)
            monitoringProgress = elapsed / durationSec
            phase = .monitoring(elapsed: elapsed, total: durationSec)

            var sample = MonitoringSample(
                timestamp: Date().timeIntervalSince1970,
                anomaly: false,
                gatewayMs: nil,
                internetMs: nil,
                signalDbm: nil,
                noiseDbm: nil
            )

            // Ping gateway
            if let gw = connection.gateway {
                sample.gatewayMs = await pingService.singlePing(target: gw, timeoutSeconds: 4)
                if let rtt = sample.gatewayMs { gwRtts.append(rtt) }
            }

            // Ping internet
            sample.internetMs = await pingService.singlePing(target: "8.8.8.8", timeoutSeconds: 4)

            // WiFi signal (every 30s)
            if connection.type == "wifi" && Date().timeIntervalSince(lastSignalTime) >= 30 {
                if let signal = await wifiService.fetchSignalStrength() {
                    sample.signalDbm = signal.rssiEstimate
                }
                lastSignalTime = Date()
            }

            // Anomaly detection
            if sample.gatewayMs == nil {
                sample.anomaly = true
            } else if gwRtts.count > 5, let gw = sample.gatewayMs {
                let recent = Array(gwRtts.suffix(20))
                let recentAvg = StatisticsHelper.mean(recent) ?? baselineGwAvg
                let threshold = Swift.max(recentAvg * 3, baselineGwAvg * 2, 30)
                if gw > threshold { sample.anomaly = true }
            }
            if sample.internetMs == nil { sample.anomaly = true }
            if let sig = sample.signalDbm, sig < -75 { sample.anomaly = true }

            if sample.anomaly { anomalies.append(sample) }

            samples.append(sample)
            recentSamples = Array(samples.suffix(50))
            currentSample = sample

            // Wait for next 5-second cycle
            let now = Date().timeIntervalSince1970
            let sleepTime = max(0.1, nextCycle - now)
            nextCycle += 5.0
            try? await Task.sleep(for: .seconds(sleepTime))
        }

        let summary = StatisticsHelper.buildMonitoringSummary(
            samples: samples, startTime: monitorStart, anomalies: anomalies
        )
        return (samples, summary)
    }

    @MainActor
    private func savePartial(_ diagnostics: DiagnosticsResult) {
        var partial = diagnostics
        partial.verdicts = VerdictGenerator.generate(from: partial)
        self.result = partial
        phase = .complete
    }
}
