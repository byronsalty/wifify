import SwiftUI

struct HomeView: View {
    @Environment(DiagnosticsEngine.self) private var engine
    @State private var showConfig = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Logo / title
            VStack(spacing: 8) {
                Image(systemName: "wifi")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)
                Text("wifify")
                    .font(.largeTitle.bold())
                Text("Network Diagnostics")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Main action
            Button {
                showConfig = true
            } label: {
                Label("Run Diagnostics", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            // Secondary actions
            VStack(spacing: 12) {
                NavigationLink {
                    PastResultsView()
                } label: {
                    Label("Past Results", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                NavigationLink {
                    LeaderboardView()
                } label: {
                    Label("Community Leaderboard", systemImage: "trophy")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
        .padding(.horizontal, 32)
        .sheet(isPresented: $showConfig) {
            ConfigurationView()
        }
    }
}
