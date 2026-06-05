import Foundation

struct Args {
    let command: String
    let values: [String: String]

    init(_ raw: [String]) {
        command = raw.dropFirst().first ?? "help"
        var values: [String: String] = [:]
        var index = 2
        while index < raw.count {
            let item = raw[index]
            if item.hasPrefix("--") {
                let key = String(item.dropFirst(2))
                if index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                    values[key] = raw[index + 1]
                    index += 2
                } else {
                    values[key] = "true"
                    index += 1
                }
            } else {
                index += 1
            }
        }
        self.values = values
    }

    func string(_ key: String, default defaultValue: String) -> String {
        values[key] ?? defaultValue
    }

    func int(_ key: String, default defaultValue: Int) -> Int {
        Int(values[key] ?? "") ?? defaultValue
    }
}
