package connect

import (
	"os"
	"runtime"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"rosettabitcoin/nodes/go/internal/crypto"
	"rosettabitcoin/nodes/go/internal/script"
	"rosettabitcoin/nodes/go/internal/storage"
	txtypes "rosettabitcoin/nodes/go/internal/tx"
)

type scriptJob struct {
	tx         *txtypes.Transaction
	txid       string
	inputIndex int
	options    *script.VerifyInputOptions
	utxo       *storage.UTXO
}

type scriptFailure struct {
	job scriptJob
	err error
}

type scriptRunner struct {
	parallel bool
	workers  int
	verifier *crypto.Verifier
	tasks    chan scriptTask
	wg       sync.WaitGroup
}

type scriptTask struct {
	index       int
	jobs        []scriptJob
	errs        []error
	workerNanos *int64
	done        *sync.WaitGroup
}

type scriptVerifyStats struct {
	workerTime time.Duration
	batches    int64
}

func newScriptRunner() *scriptRunner {
	workers := runtime.NumCPU()
	if raw := os.Getenv("GOBITNODE_PAR_SCRIPT_THREADS"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil && parsed > 0 {
			workers = parsed
		}
	}
	runner := &scriptRunner{
		parallel: os.Getenv("GOBITNODE_PAR_SCRIPT_VERIFY") == "1",
		workers:  workers,
		verifier: crypto.NewVerifier(),
	}
	if runner.parallel && runner.workers > 1 {
		runner.tasks = make(chan scriptTask, runner.workers*2)
		runner.wg.Add(runner.workers)
		for i := 0; i < runner.workers; i++ {
			go runner.worker()
		}
	}
	return runner
}

func (r *scriptRunner) worker() {
	defer r.wg.Done()
	verifier := crypto.NewVerifier()
	defer verifier.Close()
	for task := range r.tasks {
		job := task.jobs[task.index]
		options := *job.options
		options.Verifier = verifier
		start := time.Now()
		task.errs[task.index] = script.VerifyTransactionInput(*job.tx, job.inputIndex, options)
		atomic.AddInt64(task.workerNanos, time.Since(start).Nanoseconds())
		task.done.Done()
	}
}

func (r *scriptRunner) close() {
	if r.tasks != nil {
		close(r.tasks)
		r.wg.Wait()
		r.tasks = nil
	}
	if r.verifier != nil {
		r.verifier.Close()
		r.verifier = nil
	}
}

func (r *scriptRunner) mode() string {
	if r.parallel {
		return "parallel"
	}
	return "sequential"
}

func (r *scriptRunner) threads() int {
	if !r.parallel || r.workers < 1 {
		return 1
	}
	return r.workers
}

func (r *scriptRunner) cryptoContextMode() string {
	if r.parallel {
		return "libsecp256k1/reused_context_per_worker"
	}
	if r.verifier == nil {
		return "libsecp256k1/unavailable"
	}
	return r.verifier.ContextMode()
}

func (r *scriptRunner) verify(jobs []scriptJob) (*scriptFailure, scriptVerifyStats) {
	if len(jobs) == 0 {
		return nil, scriptVerifyStats{}
	}
	var workerNanos int64
	if !r.parallel || r.workers <= 1 || len(jobs) < 2 {
		for _, job := range jobs {
			options := *job.options
			options.Verifier = r.verifier
			start := time.Now()
			if err := script.VerifyTransactionInput(*job.tx, job.inputIndex, options); err != nil {
				workerNanos += time.Since(start).Nanoseconds()
				return &scriptFailure{job: job, err: err}, scriptVerifyStats{workerTime: time.Duration(workerNanos), batches: 1}
			}
			workerNanos += time.Since(start).Nanoseconds()
		}
		return nil, scriptVerifyStats{workerTime: time.Duration(workerNanos), batches: 1}
	}
	errs := make([]error, len(jobs))
	var done sync.WaitGroup
	done.Add(len(jobs))
	for i := range jobs {
		r.tasks <- scriptTask{index: i, jobs: jobs, errs: errs, workerNanos: &workerNanos, done: &done}
	}
	done.Wait()
	for i, err := range errs {
		if err != nil {
			return &scriptFailure{job: jobs[i], err: err}, scriptVerifyStats{workerTime: time.Duration(workerNanos), batches: 1}
		}
	}
	return nil, scriptVerifyStats{workerTime: time.Duration(workerNanos), batches: 1}
}
