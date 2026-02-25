import SwiftUI

/// Side-by-side comparison of two diagnostic results.
struct CompareView: View {
    let result1: DiagnosticsResult
    let result2: DiagnosticsResult

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                speedSection
                latencySection
                baselineSection
                dnsSection
                wifiSection
            }
            .padding()
        }
        .navigationTitle("Compare")
    }

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(result1.meta.label).font(.headline)
                Text(headerDetail(result1)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("vs").font(.caption.bold()).foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .trailing) {
                Text(result2.meta.label).font(.headline)
                Text(headerDetail(result2)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func headerDetail(_ result: DiagnosticsResult) -> String {
        var parts = [result.meta.osVersion]
        if let city = result.meta.location?.city {
            parts.append(city)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var speedSection: some View {
        if result1.speed.dlThroughputMbps != nil || result2.speed.dlThroughputMbps != nil {
            GroupBox("Speed") {
                VStack(spacing: 4) {
                    compareRow("Download", result1.speed.dlThroughputMbps, result2.speed.dlThroughputMbps, higherIsBetter: true)
                    compareRow("Upload", result1.speed.ulThroughputMbps, result2.speed.ulThroughputMbps, higherIsBetter: true)
                    compareRow("Bufferbloat", result1.speed.bufferbloatRatio, result2.speed.bufferbloatRatio, higherIsBetter: false)
                }
            }
        }
    }

    private var latencySection: some View {
        GroupBox("Gateway Latency") {
            VStack(spacing: 4) {
                compareRow("Average", result1.monitoringSummary.gatewayAvgMs, result2.monitoringSummary.gatewayAvgMs, higherIsBetter: false)
                compareRow("P95", result1.monitoringSummary.gatewayP95Ms, result2.monitoringSummary.gatewayP95Ms, higherIsBetter: false)
                compareRow("Loss", computeLoss(result1), computeLoss(result2), higherIsBetter: false)
            }
        }
    }

    private var baselineSection: some View {
        GroupBox("Baseline Pings") {
            VStack(spacing: 4) {
                ForEach(["gateway", "dns_google", "dns_cloudflare", "google", "apple"], id: \.self) { target in
                    let avg1 = result1.baselineLatency[target]?.avgMs
                    let avg2 = result2.baselineLatency[target]?.avgMs
                    if avg1 != nil || avg2 != nil {
                        compareRow(target, avg1, avg2, higherIsBetter: false)
                    }
                }
            }
        }
    }

    private var dnsSection: some View {
        GroupBox("DNS") {
            compareRow("Average", result1.dns.avgTimeMs, result2.dns.avgTimeMs, higherIsBetter: false)
        }
    }

    @ViewBuilder
    private var wifiSection: some View {
        if result1.wifiSignal != nil || result2.wifiSignal != nil {
            let rssi1: Double? = result1.wifiSignal?.rssiDbm.map { Double($0) }
            let rssi2: Double? = result2.wifiSignal?.rssiDbm.map { Double($0) }
            GroupBox("WiFi Signal") {
                compareRow("RSSI", rssi1, rssi2, higherIsBetter: true)
            }
        }
    }

    // MARK: - Helpers

    private func computeLoss(_ result: DiagnosticsResult) -> Double? {
        let total = result.monitoringSummary.gatewayTotal
        guard total > 0 else { return nil }
        return Double(result.monitoringSummary.gatewayLossCount) / Double(total) * 100
    }

    private func compareRow(_ label: String, _ v1: Double?, _ v2: Double?, higherIsBetter: Bool) -> some View {
        HStack {
            Text(label)
                .font(.caption.bold())
                .frame(width: 90, alignment: .leading)

            Spacer()

            Text(v1.map { formatValue($0) } ?? "—")
                .font(.caption.monospaced())
                .frame(width: 60, alignment: .trailing)

            Text(v2.map { formatValue($0) } ?? "—")
                .font(.caption.monospaced())
                .frame(width: 60, alignment: .trailing)

            deltaText(v1, v2, higherIsBetter: higherIsBetter)
                .frame(width: 50, alignment: .trailing)
        }
    }

    private func deltaText(_ v1: Double?, _ v2: Double?, higherIsBetter: Bool) -> some View {
        if let a = v1, let b = v2, a != 0 {
            let pct = (b - a) / abs(a) * 100
            let improved = higherIsBetter ? (b - a) > 0 : (b - a) < 0
            let color: Color = improved ? .green : (abs(pct) < 5 ? .secondary : .red)
            return Text(String(format: "%+.0f%%", pct))
                .font(.caption.monospaced().bold())
                .foregroundStyle(color)
        } else {
            return Text("")
                .font(.caption.monospaced().bold())
                .foregroundStyle(.secondary)
        }
    }

    private func formatValue(_ value: Double) -> String {
        if abs(value) >= 100 { return String(format: "%.0f", value) }
        return String(format: "%.1f", value)
    }
}
