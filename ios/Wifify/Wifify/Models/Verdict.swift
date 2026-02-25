import Foundation

struct Verdict: Codable {
    var category: String
    var severity: String  // "good", "warning", "bad", "info"
    var message: String
}
