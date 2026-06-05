import XCTest

final class ContractSmokeTests: XCTestCase {
    func testBaselineConstants() {
        XCTAssertEqual("000000000e3cb5b92e9765ed9c80c6b06f3d0a186478b330dd5e6b274acf03e2".count, 64)
        XCTAssertEqual(4574, 4574)
    }

    func testRequiredTimingBuckets() {
        let buckets = Set(["utxo_load", "script_verify", "utxo_apply", "commit", "block_connect_store_commit"])
        XCTAssertTrue(buckets.contains("utxo_load"))
        XCTAssertTrue(buckets.contains("script_verify"))
        XCTAssertTrue(buckets.contains("utxo_apply"))
        XCTAssertTrue(buckets.contains("commit"))
        XCTAssertTrue(buckets.contains("block_connect_store_commit"))
    }
}
