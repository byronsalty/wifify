import Foundation

enum FirebaseConfig {
    // Same credentials as the CLI tool — set after Firebase project is created
    static let projectID = "YOUR_PROJECT_ID"
    static let apiKey = "YOUR_API_KEY"

    static var firestoreBaseURL: String {
        "https://firestore.googleapis.com/v1/projects/\(projectID)/databases/(default)/documents"
    }

    static var authURL: String {
        "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=\(apiKey)"
    }

    static var isConfigured: Bool {
        projectID != "YOUR_PROJECT_ID" && apiKey != "YOUR_API_KEY"
    }
}
