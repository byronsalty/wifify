import SwiftUI

struct SummaryView: View {
    @Environment(DiagnosticsEngine.self) private var engine
    let result: DiagnosticsResult
    @State private var savedURL: URL?
    @State private var showShareSheet = false
    @State private var showUpload = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    VStack(alignment: .leading) {
                        Text("Results")
                            .font(.title.bold())
                        Text("\(result.meta.label) — \(result.meta.osVersion)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                // Connection info
                GroupBox("Connection") {
                    LabeledContent("Type", value: result.connection.type)
                    LabeledContent("Interface", value: result.connection.interface ?? "—")
                    LabeledContent("Gateway", value: result.connection.gateway ?? "—")
                    if let wifi = result.wifiSignal {
                        LabeledContent("SSID", value: wifi.ssid ?? "—")
                        if let rssi = wifi.rssiDbm {
                            LabeledContent("Signal", value: "\(rssi) dBm")
                        }
                    }
                }

                // Speed
                if result.speed.dlThroughputMbps != nil || result.speed.ulThroughputMbps != nil {
                    GroupBox("Speed") {
                        if let dl = result.speed.dlThroughputMbps {
                            LabeledContent("Download", value: String(format: "%.1f Mbps", dl))
                        }
                        if let ul = result.speed.ulThroughputMbps {
                            LabeledContent("Upload", value: String(format: "%.1f Mbps", ul))
                        }
                        if let ratio = result.speed.bufferbloatRatio {
                            LabeledContent("Bufferbloat", value: String(format: "%.1fx", ratio))
                        }
                    }
                }

                // Monitoring stats
                GroupBox("Monitoring (\(String(format: "%.0f", result.monitoringSummary.durationMin)) min)") {
                    if let avg = result.monitoringSummary.gatewayAvgMs {
                        LabeledContent("Gateway Avg", value: String(format: "%.1f ms", avg))
                    }
                    if let p95 = result.monitoringSummary.gatewayP95Ms {
                        LabeledContent("Gateway P95", value: String(format: "%.1f ms", p95))
                    }
                    LabeledContent("Gateway Loss", value: "\(result.monitoringSummary.gatewayLossCount)/\(result.monitoringSummary.gatewayTotal)")
                    LabeledContent("Anomalies", value: "\(result.monitoringSummary.anomalyCount)")
                }

                // Verdicts
                GroupBox("Diagnosis") {
                    ForEach(result.verdicts, id: \.message) { verdict in
                        HStack(alignment: .top, spacing: 8) {
                            verdictIcon(verdict.severity)
                            Text(verdict.message)
                                .font(.callout)
                        }
                        .padding(.vertical, 2)
                    }
                }

                // Actions
                VStack(spacing: 12) {
                    Button {
                        saveAndShare()
                    } label: {
                        Label("Save & Share JSON", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        showUpload = true
                    } label: {
                        Label("Upload to Community", systemImage: "arrow.up.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        engine.phase = .idle
                        engine.result = nil
                    } label: {
                        Text("New Run")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 8)
            }
            .padding()
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = savedURL {
                ShareSheet(activityItems: [url])
            }
        }
        .sheet(isPresented: $showUpload) {
            UploadView(result: result)
        }
    }

    private func verdictIcon(_ severity: String) -> some View {
        switch severity {
        case "good":
            return Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "warning":
            return Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case "bad":
            return Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        default:
            return Image(systemName: "info.circle.fill").foregroundStyle(.blue)
        }
    }

    private func saveAndShare() {
        do {
            let url = try JSONExporter.save(result)
            savedURL = url
            showShareSheet = true
        } catch {
            // Could show alert here
        }
    }
}

/// UIKit share sheet wrapper.
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
