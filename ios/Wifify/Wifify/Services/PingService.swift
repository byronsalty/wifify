import Foundation

protocol PingServiceProtocol: Sendable {
    func ping(target: String, count: Int) async -> PingResult
    func singlePing(target: String, timeoutSeconds: Double) async -> Double?
}

/// ICMP ping using Apple's SimplePing (works on physical devices, not simulator).
final class PingService: NSObject, PingServiceProtocol, @unchecked Sendable {

    func ping(target: String, count: Int = 20) async -> PingResult {
        var rtts: [Double] = []
        var transmitted = 0
        var received = 0

        for _ in 0..<count {
            transmitted += 1
            if let rtt = await singlePing(target: target, timeoutSeconds: 5.0) {
                rtts.append(rtt)
                received += 1
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        let lossPct = transmitted > 0 ? Double(transmitted - received) / Double(transmitted) * 100.0 : 0

        return PingResult(
            target: target,
            label: "",
            count: count,
            transmitted: transmitted,
            received: received,
            packetLossPct: round(lossPct * 10) / 10,
            minMs: rtts.min(),
            avgMs: StatisticsHelper.mean(rtts),
            maxMs: rtts.max(),
            stddevMs: StatisticsHelper.stddev(rtts),
            jitterMs: StatisticsHelper.jitter(rtts),
            rttsMs: rtts,
            error: nil
        )
    }

    func singlePing(target: String, timeoutSeconds: Double = 5.0) async -> Double? {
        #if targetEnvironment(simulator)
        // SimplePing doesn't work on the simulator — return synthetic data
        try? await Task.sleep(for: .milliseconds(Int.random(in: 3...25)))
        return Double.random(in: 2...30)
        #else
        return await withCheckedContinuation { continuation in
            let helper = PingHelper(target: target, timeout: timeoutSeconds) { rtt in
                continuation.resume(returning: rtt)
            }
            helper.start()
        }
        #endif
    }
}

/// Helper that wraps SimplePing's delegate pattern into a single callback.
private final class PingHelper: NSObject, SimplePingDelegate {
    private let pinger: SimplePing
    private let timeout: Double
    private let completion: (Double?) -> Void
    private var sendTime: CFAbsoluteTime = 0
    private var completed = false
    private var timeoutTimer: Timer?

    init(target: String, timeout: Double, completion: @escaping (Double?) -> Void) {
        self.pinger = SimplePing(hostName: target)
        self.timeout = timeout
        self.completion = completion
        super.init()
        self.pinger.addressStyle = SimplePingAddressStyle(rawValue: 1)!
        self.pinger.delegate = self
    }

    func start() {
        DispatchQueue.main.async {
            self.pinger.start()
            self.timeoutTimer = Timer.scheduledTimer(withTimeInterval: self.timeout, repeats: false) { [weak self] _ in
                self?.finish(rtt: nil)
            }
        }
    }

    private func finish(rtt: Double?) {
        guard !completed else { return }
        completed = true
        timeoutTimer?.invalidate()
        pinger.stop()
        completion(rtt)
    }

    // MARK: - SimplePingDelegate

    func simplePing(_ pinger: SimplePing, didStartWithAddress address: Data) {
        pinger.send(with: nil)
        sendTime = CFAbsoluteTimeGetCurrent()
    }

    func simplePing(_ pinger: SimplePing, didFailWithError error: Error) {
        finish(rtt: nil)
    }

    func simplePing(_ pinger: SimplePing, didSendPacket packet: Data, sequenceNumber: UInt16) {
        // Packet sent, waiting for response
    }

    func simplePing(_ pinger: SimplePing, didFailToSendPacket packet: Data, sequenceNumber: UInt16, error: Error) {
        finish(rtt: nil)
    }

    func simplePing(_ pinger: SimplePing, didReceivePingResponsePacket packet: Data, sequenceNumber: UInt16) {
        let rtt = (CFAbsoluteTimeGetCurrent() - sendTime) * 1000.0 // ms
        finish(rtt: round(rtt * 100) / 100)
    }

    func simplePing(_ pinger: SimplePing, didReceiveUnexpectedPacket packet: Data) {
        // Ignore unexpected packets
    }
}
