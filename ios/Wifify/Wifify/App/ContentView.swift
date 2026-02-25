import SwiftUI

struct ContentView: View {
    @Environment(DiagnosticsEngine.self) private var engine

    var body: some View {
        NavigationStack {
            switch engine.phase {
            case .idle:
                HomeView()
            case .baseline, .monitoring, .summary:
                DiagnosticsView()
            case .complete:
                if let result = engine.result {
                    SummaryView(result: result)
                } else {
                    HomeView()
                }
            case .error(let message):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text("Error")
                        .font(.title2.bold())
                    Text(message)
                        .foregroundStyle(.secondary)
                    Button("Back") {
                        engine.phase = .idle
                    }
                }
                .padding()
            }
        }
    }
}
