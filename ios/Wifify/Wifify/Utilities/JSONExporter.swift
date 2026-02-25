import Foundation

enum JSONExporter {

    static func export(_ result: DiagnosticsResult) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(result)
    }

    static func save(_ result: DiagnosticsResult) throws -> URL {
        let data = try export(result)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "wifify_\(result.meta.label)_\(formatter.string(from: Date())).json"
        let url = docs.appendingPathComponent(filename)
        try data.write(to: url)
        return url
    }

    static func loadAll() -> [(url: URL, result: DiagnosticsResult)] {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("wifify_") }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }

            return files.compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let result = try? JSONDecoder().decode(DiagnosticsResult.self, from: data) else {
                    return nil
                }
                return (url, result)
            }
        } catch {
            return []
        }
    }

    static func delete(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}
