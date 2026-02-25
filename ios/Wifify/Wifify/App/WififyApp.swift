import SwiftUI

@main
struct WififyApp: App {
    @State private var engine = DiagnosticsEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(engine)
        }
    }
}
