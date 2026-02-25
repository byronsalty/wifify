import SwiftUI

struct UploadView: View {
    let result: DiagnosticsResult
    @Environment(\.dismiss) private var dismiss

    @State private var handle = ""
    @State private var network = "private"
    @State private var isp = ""
    @State private var isUploading = false
    @State private var uploadError: String?
    @State private var uploadSuccess = false

    private let networks = ["private", "public"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Your Info") {
                    TextField("Handle / display name", text: $handle)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Picker("Network Type", selection: $network) {
                        Text("Private (home, office)").tag("private")
                        Text("Public (hotel, cafe)").tag("public")
                    }

                    TextField("ISP (optional)", text: $isp)
                }

                Section("What gets uploaded") {
                    Text("Connection type, speed, latency stats, signal strength, anomaly count, platform, and approximate location (city/region). No raw monitoring data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = uploadError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                if uploadSuccess {
                    Section {
                        Label("Uploaded successfully!", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Upload to Community")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Upload") {
                        upload()
                    }
                    .bold()
                    .disabled(handle.isEmpty || isUploading || uploadSuccess)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func upload() {
        isUploading = true
        uploadError = nil

        Task {
            do {
                try await FirestoreService.upload(
                    result: result,
                    handle: handle,
                    network: network,
                    isp: isp.isEmpty ? nil : isp
                )
                uploadSuccess = true
            } catch {
                uploadError = error.localizedDescription
            }
            isUploading = false
        }
    }
}
