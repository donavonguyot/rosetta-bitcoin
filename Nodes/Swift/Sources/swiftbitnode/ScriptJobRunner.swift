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

struct ScriptJobRunnerResult: Sendable {
    let failure: ScriptVerifyFailure?
    let workerMicros: Int64
    let wallMicros: Int64
    let waitMicros: Int64
    let workerCount: Int
    let workerLocalSecp: Bool
}

final class ScriptJobRunner: @unchecked Sendable {
    private let workerCount: Int
    private let lanes: [DispatchQueue]
    private let contexts: [NativeSecp256k1.Context?]

    init(workerCount requestedWorkerCount: Int? = nil) {
        let envWorkers = Int(ProcessInfo.processInfo.environment["SCRIPT_VERIFY_WORKERS"] ?? "")
            ?? Int(ProcessInfo.processInfo.environment["SCRIPT_THREADS"] ?? "")
        let defaultWorkers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        self.workerCount = max(1, requestedWorkerCount ?? envWorkers ?? defaultWorkers)
        self.lanes = (0..<workerCount).map { index in
            DispatchQueue(label: "swiftbitnode.script.runner.\(index)")
        }
        self.contexts = (0..<workerCount).map { _ in NativeSecp256k1.makeContext() }
    }

    var usesWorkerLocalSecp: Bool {
        NativeSecp256k1.available && contexts.allSatisfy { $0 != nil }
    }

    var workers: Int {
        workerCount
    }

    static func verify(_ jobs: [ScriptVerifyJob]) -> ScriptJobRunnerResult {
        ScriptJobRunner(workerCount: 1).verify(jobs)
    }

    func verify(_ jobs: [ScriptVerifyJob]) -> ScriptJobRunnerResult {
        guard !jobs.isEmpty else {
            return ScriptJobRunnerResult(
                failure: nil,
                workerMicros: 0,
                wallMicros: 0,
                waitMicros: 0,
                workerCount: workerCount,
                workerLocalSecp: usesWorkerLocalSecp
            )
        }
        let wallStarted = DispatchTime.now().uptimeNanoseconds
        let results = ScriptBatchResults(count: jobs.count)
        var partitions = Array(repeating: [Int](), count: min(workerCount, jobs.count))
        for index in jobs.indices {
            partitions[index % partitions.count].append(index)
        }

        let group = DispatchGroup()
        for workerIndex in partitions.indices where !partitions[workerIndex].isEmpty {
            let workerJobs = partitions[workerIndex]
            group.enter()
            lanes[workerIndex].async {
                let context = self.contexts[workerIndex]
                NativeSecp256k1.withThreadLocalContext(context) {
                    for jobIndex in workerJobs {
                        self.run(jobs[jobIndex], index: jobIndex, results: results)
                    }
                }
                group.leave()
            }
        }
        let waitStarted = DispatchTime.now().uptimeNanoseconds
        group.wait()
        let waitMicros = Int64((DispatchTime.now().uptimeNanoseconds - waitStarted) / 1_000)
        let wallMicros = Int64((DispatchTime.now().uptimeNanoseconds - wallStarted) / 1_000)
        let snapshot = results.snapshot()
        for index in jobs.indices {
            guard let result = snapshot.results[index] else {
                return ScriptJobRunnerResult(
                    failure: ScriptVerifyFailure(
                        job: jobs[index],
                        result: ScriptVerificationResult((false, "internal", "missing_verify_result", "script job did not report a result"))
                    ),
                    workerMicros: snapshot.workerMicros,
                    wallMicros: wallMicros,
                    waitMicros: waitMicros,
                    workerCount: workerCount,
                    workerLocalSecp: usesWorkerLocalSecp
                )
            }
            if !result.passed {
                return ScriptJobRunnerResult(
                    failure: ScriptVerifyFailure(job: jobs[index], result: result),
                    workerMicros: snapshot.workerMicros,
                    wallMicros: wallMicros,
                    waitMicros: waitMicros,
                    workerCount: workerCount,
                    workerLocalSecp: usesWorkerLocalSecp
                )
            }
        }
        return ScriptJobRunnerResult(
            failure: nil,
            workerMicros: snapshot.workerMicros,
            wallMicros: wallMicros,
            waitMicros: waitMicros,
            workerCount: workerCount,
            workerLocalSecp: usesWorkerLocalSecp
        )
    }

    private func run(_ job: ScriptVerifyJob, index: Int, results: ScriptBatchResults) {
        let started = DispatchTime.now().uptimeNanoseconds
        let result = ScriptVerificationResult(ScriptVerifier.verify(job.fixture, cache: job.cache))
        let micros = Int64((DispatchTime.now().uptimeNanoseconds - started) / 1_000)
        results.set(result, micros: micros, at: index)
    }
}
