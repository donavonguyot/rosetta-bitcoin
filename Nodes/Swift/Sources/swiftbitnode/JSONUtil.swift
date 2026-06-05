import Foundation

enum Json {
    static func write(_ value: Any, to path: String?) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        if let path, !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    static func loadObject(path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SwiftBitnodeError.message("expected JSON object at \(path)")
        }
        return object
    }
}

enum SwiftBitnodeError: Error, LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(value): return value
        }
    }
}
