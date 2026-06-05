import Foundation
import Dispatch

struct ScriptVerifyJob: Sendable {
    let txIndex: Int
    let inputIndex: Int
    let fixture: CorpusFixture
    let cache: Sighash.Cache?
}

struct ScriptVerificationResult: Sendable {
    let passed: Bool
    let stage: String
    let type: String
    let message: String

    init(_ result: (passed: Bool, stage: String, type: String, message: String)) {
        self.passed = result.passed
        self.stage = result.stage
        self.type = result.type
        self.message = result.message
    }
}

struct ScriptVerifyFailure: Sendable {
    let job: ScriptVerifyJob
    let result: ScriptVerificationResult
}

private final class ScriptBatchResults: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ScriptVerificationResult?]
    private var workerMicros: Int64 = 0

    init(count: Int) {
        self.results = Array(repeating: nil, count: count)
    }

    func set(_ result: ScriptVerificationResult, micros: Int64, at index: Int) {
        lock.lock()
        results[index] = result
        workerMicros += micros
        lock.unlock()
    }

    func snapshot() -> (results: [ScriptVerificationResult?], workerMicros: Int64) {
        lock.lock()
        let out = (results, workerMicros)
        lock.unlock()
        return out
    }
}

enum ScriptJobRunner {
    static func verify(_ jobs: [ScriptVerifyJob]) -> (failure: ScriptVerifyFailure?, workerMicros: Int64) {
        guard !jobs.isEmpty else {
            return (nil, 0)
        }
        let results = ScriptBatchResults(count: jobs.count)
        if jobs.count == 1 {
            run(jobs[0], index: 0, results: results)
        } else {
            DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
                run(jobs[index], index: index, results: results)
            }
        }
        let snapshot = results.snapshot()
        for index in jobs.indices {
            guard let result = snapshot.results[index] else {
                return (
                    ScriptVerifyFailure(
                        job: jobs[index],
                        result: ScriptVerificationResult((false, "internal", "missing_verify_result", "script job did not report a result"))
                    ),
                    snapshot.workerMicros
                )
            }
            if !result.passed {
                return (ScriptVerifyFailure(job: jobs[index], result: result), snapshot.workerMicros)
            }
        }
        return (nil, snapshot.workerMicros)
    }

    private static func run(_ job: ScriptVerifyJob, index: Int, results: ScriptBatchResults) {
        let started = DispatchTime.now().uptimeNanoseconds
        let result = ScriptVerificationResult(ScriptVerifier.verify(job.fixture, cache: job.cache))
        let micros = Int64((DispatchTime.now().uptimeNanoseconds - started) / 1_000)
        results.set(result, micros: micros, at: index)
    }
}
