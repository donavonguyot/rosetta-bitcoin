import XCTest

final class ConsensusRegressionTests: XCTestCase {
    func testConsensusSelfTestCommandPasses() throws {
        try assertCommandPasses(["consensus-self-test"])
    }

    func testPerformanceSelfTestCommandPasses() throws {
        try assertCommandPasses(["performance-self-test"])
    }

    private func assertCommandPasses(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/swiftbitnode")
        process.arguments = arguments
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
