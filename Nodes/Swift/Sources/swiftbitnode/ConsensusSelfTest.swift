import Foundation

enum ConsensusSelfTest {
    static func run() throws -> [String: Any] {
        let checks: [(String, () throws -> Bool)] = [
            ("cltv_rejects_unreached_locktime", testCLTVRejectsUnreachedLocktime),
            ("csv_rejects_version_one", testCSVRejectsVersionOne),
            ("native_p2wpkh_rejects_scriptsig", testNativeP2WPKHRejectsScriptSig),
            ("p2sh_nested_p2wpkh_routes_to_witness", testP2SHNestedP2WPKHRoutesToWitness)
        ]
        var results: [[String: Any]] = []
        var passed = 0
        for (name, check) in checks {
            do {
                let ok = try check()
                if ok { passed += 1 }
                results.append(["name": name, "result": ok ? "passed" : "failed"])
            } catch {
                results.append(["name": name, "result": "failed", "error": error.localizedDescription])
            }
        }
        return [
            "schema": "swiftbitnode.consensus_self_test.v1",
            "result": passed == checks.count ? "passed" : "failed",
            "passed": passed,
            "failed": checks.count - passed,
            "checks": results
        ]
    }

    private static func testCLTVRejectsUnreachedLocktime() throws -> Bool {
        let tx = makeTransaction(version: 2, locktime: 10, sequence: 0xfffffffe)
        let context = scriptContext(tx: tx)
        do {
            _ = try ScriptInterpreter.evaluate(script: Data([0x01, 0x0b, 0xb1, 0x51]), context: context)
            return false
        } catch {
            return true
        }
    }

    private static func testCSVRejectsVersionOne() throws -> Bool {
        let tx = makeTransaction(version: 1, locktime: 0, sequence: 10)
        let context = scriptContext(tx: tx)
        do {
            _ = try ScriptInterpreter.evaluate(script: Data([0x01, 0x01, 0xb2, 0x51]), context: context)
            return false
        } catch {
            return true
        }
    }

    private static func testNativeP2WPKHRejectsScriptSig() throws -> Bool {
        let prevScript = Data([0x00, 0x14]) + Data(repeating: 1, count: 20)
        let tx = makeTransaction(scriptSig: Data([0x51]), witness: [[Data(), Data(repeating: 2, count: 33)]])
        let result = ScriptVerifier.verify(fixture(tx: tx, prevScript: prevScript))
        return !result.passed && result.type == "native_segwit_scriptsig_nonempty"
    }

    private static func testP2SHNestedP2WPKHRoutesToWitness() throws -> Bool {
        let redeemScript = Data([0x00, 0x14]) + Data(repeating: 3, count: 20)
        var scriptSig = Data()
        scriptSig.append(UInt8(redeemScript.count))
        scriptSig.append(redeemScript)
        let prevScript = Data([0xa9, 0x14]) + Hash.hash160(redeemScript) + Data([0x87])
        let tx = makeTransaction(scriptSig: scriptSig, witness: [[Data()]])
        let result = ScriptVerifier.verify(fixture(tx: tx, prevScript: prevScript))
        return !result.passed && result.type == "p2wpkh_witness_shape"
    }

    private static func scriptContext(tx: Transaction) -> ScriptInterpreter.Context {
        ScriptInterpreter.Context(
            transaction: tx,
            inputIndex: 0,
            tapscript: false,
            maxScriptElementSize: 520,
            maxScriptNumSize: 4,
            codeSeparatorCallback: nil
        )
    }

    private static func fixture(tx: Transaction, prevScript: Data) -> CorpusFixture {
        CorpusFixture(
            fixtureID: "self-test",
            height: 0,
            blockHash: "",
            txid: tx.txid,
            inputIndex: 0,
            transaction: tx,
            prevouts: [CorpusPrevout(amount: 1_000, scriptPubKey: prevScript)],
            prevScriptPubKey: prevScript,
            loadedFiles: 0,
            fileHashes: [:]
        )
    }

    private static func makeTransaction(
        version: Int32 = 2,
        locktime: UInt32 = 0,
        sequence: UInt32 = 0xfffffffe,
        scriptSig: Data = Data(),
        witness: [[Data]] = [[]]
    ) -> Transaction {
        Transaction(
            version: version,
            rawNoWitness: Data(),
            rawWithWitness: Data(),
            inputs: [TxInput(previousTxidInternal: Data(repeating: 1, count: 32), vout: 0, scriptSig: scriptSig, sequence: sequence)],
            outputs: [TxOutput(value: 500, scriptPubKey: Data([0x51]))],
            witness: witness,
            locktime: locktime,
            txid: "self-test-txid",
            wtxid: "self-test-wtxid",
            hasWitness: !witness.isEmpty
        )
    }
}
