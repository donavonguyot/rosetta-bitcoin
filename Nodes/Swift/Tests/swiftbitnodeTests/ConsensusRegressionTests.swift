import XCTest

final class ConsensusRegressionTests: XCTestCase {
    func testConsensusSelfTestCommandPasses() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/swiftbitnode")
        process.arguments = ["consensus-self-test"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(json?["result"] as? String, "passed")
        XCTAssertEqual(json?["failed"] as? Int, 0)
    }
}
