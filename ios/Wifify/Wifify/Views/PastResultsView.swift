import SwiftUI

struct PastResultsView: View {
    @State private var results: [(url: URL, result: DiagnosticsResult)] = []
    @State private var selectedForCompare: [URL] = []
    @State private var showCompare = false

    var body: some View {
        Group {
            if results.isEmpty {
                ContentUnavailableView(
                    "No Results Yet",
                    systemImage: "doc.text",
                    description: Text("Run a diagnostic session to see results here.")
                )
            } else {
                List {
                    ForEach(results, id: \.url) { item in
                        NavigationLink {
                            ResultDetailView(result: item.result)
                        } label: {
                            resultRow(item)
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            try? JSONExporter.delete(results[index].url)
                        }
                        results.remove(atOffsets: indexSet)
                    }
                }
            }
        }
        .navigationTitle("Past Results")
        .onAppear {
            results = JSONExporter.loadAll()
        }
        .toolbar {
            if results.count >= 2 {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink("Compare") {
                        ComparePickerView(results: results)
                    }
                }
            }
        }
    }

    private func resultRow(_ item: (url: URL, result: DiagnosticsResult)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.result.meta.label)
                    .font(.headline)
                Spacer()
                Text(item.result.meta.osVersion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(item.result.meta.timestamp.prefix(19).replacingOccurrences(of: "T", with: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let dl = item.result.speed.dlThroughputMbps {
                    Text(String(format: "%.0f Mbps", dl))
                        .font(.caption.bold())
                }
            }
        }
    }
}

/// Simple picker to choose two results for comparison.
struct ComparePickerView: View {
    let results: [(url: URL, result: DiagnosticsResult)]
    @State private var first: Int = 0
    @State private var second: Int = 1

    var body: some View {
        Form {
            Section("First Result") {
                Picker("First", selection: $first) {
                    ForEach(results.indices, id: \.self) { i in
                        Text("\(results[i].result.meta.label) — \(String(results[i].result.meta.timestamp.prefix(10)))")
                            .tag(i)
                    }
                }
            }

            Section("Second Result") {
                Picker("Second", selection: $second) {
                    ForEach(results.indices, id: \.self) { i in
                        Text("\(results[i].result.meta.label) — \(String(results[i].result.meta.timestamp.prefix(10)))")
                            .tag(i)
                    }
                }
            }

            if first != second {
                Section {
                    NavigationLink("Compare") {
                        CompareView(
                            result1: results[first].result,
                            result2: results[second].result
                        )
                    }
                }
            }
        }
        .navigationTitle("Compare")
    }
}

/// Detail view for a single result file.
struct ResultDetailView: View {
    let result: DiagnosticsResult

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Meta") {
                    LabeledContent("Label", value: result.meta.label)
                    LabeledContent("Platform", value: result.meta.platform ?? "—")
                    LabeledContent("OS", value: result.meta.osVersion)
                    LabeledContent("Duration", value: "\(Int(result.meta.durationMin)) min")
                    LabeledContent("Time", value: String(result.meta.timestamp.prefix(19)))
                }

                GroupBox("Baseline Latency") {
                    ForEach(Array(result.baselineLatency.keys.sorted()), id: \.self) { key in
                        if let ping = result.baselineLatency[key] {
                            HStack {
                                Text(key).font(.caption.bold())
                                Spacer()
                                if let avg = ping.avgMs {
                                    Text(String(format: "%.1fms", avg))
                                }
                                Text(String(format: "%.1f%% loss", ping.packetLossPct))
                                    .foregroundStyle(ping.packetLossPct > 0 ? .red : .secondary)
                                    .font(.caption)
                            }
                        }
                    }
                }

                ForEach(result.verdicts, id: \.message) { verdict in
                    HStack(alignment: .top) {
                        Circle()
                            .fill(verdictColor(verdict.severity))
                            .frame(width: 8, height: 8)
                            .padding(.top, 5)
                        Text(verdict.message)
                            .font(.callout)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(result.meta.label)
    }

    private func verdictColor(_ severity: String) -> Color {
        switch severity {
        case "good": return .green
        case "warning": return .orange
        case "bad": return .red
        default: return .blue
        }
    }
}
