import SwiftUI

struct LeaderboardView: View {
    @State private var network = "private"
    @State private var connection = "wifi"
    @State private var metric = "download"
    @State private var entries: [FirestoreService.LeaderboardEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let metrics: [(key: String, label: String)] = [
        ("download", "Download"),
        ("upload", "Upload"),
        ("latency", "Latency"),
        ("rpm", "RPM"),
        ("bufferbloat", "Bufferbloat"),
    ]

    private let metricFields: [String: String] = [
        "download": "download_mbps",
        "upload": "upload_mbps",
        "latency": "gateway_latency_avg",
        "rpm": "rpm",
        "bufferbloat": "bufferbloat_ratio",
    ]

    private let metricUnits: [String: String] = [
        "download": "Mbps",
        "upload": "Mbps",
        "latency": "ms",
        "rpm": "RPM",
        "bufferbloat": "x",
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Filters
            VStack(spacing: 8) {
                HStack {
                    Picker("Network", selection: $network) {
                        Text("Private").tag("private")
                        Text("Public").tag("public")
                    }
                    .pickerStyle(.segmented)

                    Picker("Connection", selection: $connection) {
                        Text("WiFi").tag("wifi")
                        Text("Wired").tag("wired")
                    }
                    .pickerStyle(.segmented)
                }

                Picker("Metric", selection: $metric) {
                    ForEach(metrics, id: \.key) { m in
                        Text(m.label).tag(m.key)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding()

            // Results
            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if let error = errorMessage {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else if entries.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "No Results",
                    systemImage: "trophy",
                    description: Text("No results yet for \(network) \(connection). Be the first!")
                )
                Spacer()
            } else {
                List {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        HStack {
                            Text("#\(index + 1)")
                                .font(.caption.bold())
                                .frame(width: 30, alignment: .leading)
                                .foregroundStyle(index < 3 ? .yellow : .secondary)

                            VStack(alignment: .leading) {
                                Text(entry.handle)
                                    .font(.callout.bold())
                                HStack(spacing: 4) {
                                    Text(entry.os)
                                    if let isp = entry.isp {
                                        Text("/ \(isp)")
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(formatValue(entry.value))
                                .font(.callout.monospaced().bold())

                            Text(metricUnits[metric] ?? "")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Leaderboard")
        .onChange(of: network) { _, _ in fetchLeaderboard() }
        .onChange(of: connection) { _, _ in fetchLeaderboard() }
        .onChange(of: metric) { _, _ in fetchLeaderboard() }
        .onAppear { fetchLeaderboard() }
    }

    private func fetchLeaderboard() {
        guard let field = metricFields[metric] else { return }
        isLoading = true
        errorMessage = nil

        Task {
            do {
                entries = try await FirestoreService.fetchLeaderboard(
                    network: network, connection: connection, metricField: field
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func formatValue(_ value: Double) -> String {
        if abs(value) >= 100 { return String(format: "%.0f", value) }
        return String(format: "%.1f", value)
    }
}
