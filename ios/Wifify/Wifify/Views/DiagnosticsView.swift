import SwiftUI

/// Live view during Phase 1 (baseline) and Phase 2 (monitoring).
struct DiagnosticsView: View {
    @Environment(DiagnosticsEngine.self) private var engine

    var body: some View {
        VStack(spacing: 0) {
            switch engine.phase {
            case .baseline(let step):
                baselineView(step: step)
            case .monitoring(let elapsed, let total):
                monitoringView(elapsed: elapsed, total: total)
            case .summary:
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Generating summary...")
                        .foregroundStyle(.secondary)
                }
            default:
                EmptyView()
            }
        }
        .keepAwake(true)
        .navigationTitle("wifify")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Stop") {
                    engine.cancel()
                }
                .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Baseline

    private func baselineView(step: String) -> some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 12) {
                Text("Phase 1: Baseline")
                    .font(.title2.bold())
                Text(step)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: engine.baselineProgress)
                .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Monitoring

    private func monitoringView(elapsed: TimeInterval, total: TimeInterval) -> some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Text("Phase 2: Monitoring")
                    .font(.title3.bold())

                ProgressView(value: engine.monitoringProgress)
                    .padding(.horizontal)

                HStack {
                    Text(formatDuration(elapsed))
                    Spacer()
                    Text(formatDuration(total - elapsed) + " remaining")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.horizontal)
            }
            .padding()

            // Live sample table
            List {
                ForEach(engine.recentSamples.suffix(30), id: \.timestamp) { sample in
                    sampleRow(sample)
                }
            }
            .listStyle(.plain)
        }
    }

    private func sampleRow(_ sample: MonitoringSample) -> some View {
        HStack(spacing: 12) {
            Text(formatTime(sample.timestamp))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            if let gw = sample.gatewayMs {
                Text(String(format: "%.1fms", gw))
                    .font(.caption.monospaced())
                    .foregroundStyle(gw > 30 ? .orange : .primary)
            } else {
                Text("LOSS")
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(.red)
            }

            if let inet = sample.internetMs {
                Text(String(format: "%.1fms", inet))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                Text("LOSS")
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
            }

            if let sig = sample.signalDbm {
                Text("\(sig) dBm")
                    .font(.caption.monospaced())
                    .foregroundStyle(sig < -70 ? .orange : .green)
            }

            Spacer()

            if sample.anomaly {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }
        }
    }

    // MARK: - Formatting

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func formatTime(_ epoch: Double) -> String {
        let date = Date(timeIntervalSince1970: epoch)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
