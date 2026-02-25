import Foundation

protocol SpeedTestServiceProtocol: Sendable {
    func runSpeedTest(pingService: PingServiceProtocol, gateway: String?) async -> SpeedResult
}

final class SpeedTestService: SpeedTestServiceProtocol {
    // Cloudflare's speed test endpoints — publicly accessible
    private let downloadURL = URL(string: "https://speed.cloudflare.com/__down?bytes=50000000")! // 50MB
    private let uploadURL = URL(string: "https://speed.cloudflare.com/__up")!

    func runSpeedTest(pingService: PingServiceProtocol, gateway: String?) async -> SpeedResult {
        // Step 1: Measure idle latency
        let idleLatency = await measureIdleLatency(pingService: pingService, target: gateway ?? "8.8.8.8")

        // Step 2: Download test
        let dlMbps = await measureDownload()

        // Step 3: Upload test
        let ulMbps = await measureUpload()

        // Step 4: Bufferbloat — ping during a brief download
        let loadedLatency = await measureLoadedLatency(pingService: pingService, target: gateway ?? "8.8.8.8")

        var bufferbloatMs: Double?
        var bufferbloatRatio: Double?
        if let idle = idleLatency, let loaded = loadedLatency, idle > 0 {
            bufferbloatMs = round((loaded - idle) * 10) / 10
            bufferbloatRatio = round(loaded / idle * 10) / 10
        }

        return SpeedResult(
            dlThroughputMbps: dlMbps,
            ulThroughputMbps: ulMbps,
            responsivenessRpm: nil, // Not measurable on iOS
            baseRttMs: idleLatency,
            idleLatencyMs: idleLatency,
            loadedLatencyMs: loadedLatency,
            bufferbloatMs: bufferbloatMs,
            bufferbloatRatio: bufferbloatRatio,
            interfaceName: nil,
            error: nil
        )
    }

    private func measureDownload() async -> Double? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)

        let start = CFAbsoluteTimeGetCurrent()
        do {
            let (data, response) = try await session.data(from: downloadURL)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            guard elapsed > 0 else { return nil }
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }
            let bits = Double(data.count) * 8
            return round(bits / elapsed / 1_000_000 * 100) / 100
        } catch {
            return nil
        }
    }

    private func measureUpload() async -> Double? {
        let uploadSize = 10_000_000 // 10MB
        let data = Data((0..<uploadSize).map { _ in UInt8.random(in: 0...255) })

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)

        let start = CFAbsoluteTimeGetCurrent()
        do {
            let (_, response) = try await session.upload(for: request, from: data)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            guard elapsed > 0 else { return nil }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return nil }
            let bits = Double(uploadSize) * 8
            return round(bits / elapsed / 1_000_000 * 100) / 100
        } catch {
            return nil
        }
    }

    private func measureIdleLatency(pingService: PingServiceProtocol, target: String) async -> Double? {
        var rtts: [Double] = []
        for _ in 0..<10 {
            if let rtt = await pingService.singlePing(target: target, timeoutSeconds: 3) {
                rtts.append(rtt)
            }
        }
        guard !rtts.isEmpty else { return nil }
        return StatisticsHelper.percentile(rtts.sorted(), 50) // Median
    }

    /// Ping during a concurrent download to measure latency under load.
    private func measureLoadedLatency(pingService: PingServiceProtocol, target: String) async -> Double? {
        // Start a download in the background
        let downloadTask = Task<Void, Never> {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForResource = 15
            let session = URLSession(configuration: config)
            _ = try? await session.data(from: downloadURL)
        }

        // Wait a moment for the download to saturate the link
        try? await Task.sleep(for: .seconds(2))

        // Ping while download is running
        var rtts: [Double] = []
        for _ in 0..<10 {
            if let rtt = await pingService.singlePing(target: target, timeoutSeconds: 3) {
                rtts.append(rtt)
            }
        }

        downloadTask.cancel()

        guard !rtts.isEmpty else { return nil }
        return StatisticsHelper.percentile(rtts.sorted(), 50)
    }
}
