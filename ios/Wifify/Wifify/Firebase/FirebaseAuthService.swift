import Foundation

enum FirebaseAuthService {

    struct AuthResponse: Decodable {
        let idToken: String
    }

    /// Get an anonymous auth token from Firebase.
    static func anonymousAuth() async throws -> String {
        let url = URL(string: FirebaseConfig.authURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["returnSecureToken": true])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
        return authResponse.idToken
    }
}
