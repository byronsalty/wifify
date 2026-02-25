import SwiftUI

struct ConfigurationView: View {
    @Environment(DiagnosticsEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var duration: Double = 15
    private let durations: [Double] = [1, 5, 10, 15, 30]

    var body: some View {
        @Bindable var engine = engine

        NavigationStack {
            Form {
                Section("Run Label") {
                    TextField("Auto-detected (wifi/ethernet/cellular)", text: $label)
                        .autocorrectionDisabled()
                }

                Section("Monitoring Duration") {
                    Picker("Duration", selection: $duration) {
                        ForEach(durations, id: \.self) { d in
                            Text("\(Int(d)) min").tag(d)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Text("The app must stay in the foreground during monitoring. The screen will stay on automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Configure Run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        engine.label = label
                        engine.durationMinutes = duration
                        engine.run()
                        dismiss()
                    }
                    .bold()
                }
            }
        }
        .presentationDetents([.medium])
    }
}
