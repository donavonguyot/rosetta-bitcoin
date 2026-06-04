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
	tx         txtypes.Transaction
	txid       string
	inputIndex int
	options    script.VerifyInputOptions
	input      txtypes.TxIn
	utxo       storage.UTXO
}

type scriptFailure struct {
	job scriptJob
	err error
}

type scriptRunner struct {
	parallel bool
	workers  int
	verifier *crypto.Verifier
}

func newScriptRunner() scriptRunner {
	workers := runtime.NumCPU()
	if raw := os.Getenv("GOBITNODE_PAR_SCRIPT_THREADS"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil && parsed > 0 {
			workers = parsed
		}
	}
	return scriptRunner{
		parallel: os.Getenv("GOBITNODE_PAR_SCRIPT_VERIFY") == "1",
		workers:  workers,
		verifier: crypto.NewVerifier(),
	}
}

func (r scriptRunner) close() {
	if r.verifier != nil {
		r.verifier.Close()
	}
}

func (r scriptRunner) mode() string {
	if r.parallel {
		return "parallel"
	}
	return "sequential"
}

func (r scriptRunner) threads() int {
	if !r.parallel || r.workers < 1 {
		return 1
	}
	return r.workers
}

func (r scriptRunner) cryptoContextMode() string {
	if r.parallel {
		return "libsecp256k1/reused_context_per_worker"
	}
	if r.verifier == nil {
		return "libsecp256k1/unavailable"
	}
	return r.verifier.ContextMode()
}

func (r scriptRunner) verify(jobs []scriptJob) (*scriptFailure, time.Duration) {
	if len(jobs) == 0 {
		return nil, 0
	}
	var workerNanos int64
	if !r.parallel || r.workers <= 1 || len(jobs) < 2 {
		for _, job := range jobs {
			job.options.Verifier = r.verifier
			start := time.Now()
			if err := script.VerifyTransactionInput(job.tx, job.inputIndex, job.options); err != nil {
				workerNanos += time.Since(start).Nanoseconds()
				return &scriptFailure{job: job, err: err}, time.Duration(workerNanos)
			}
			workerNanos += time.Since(start).Nanoseconds()
		}
		return nil, time.Duration(workerNanos)
	}
	errs := make([]error, len(jobs))
	next := make(chan int)
	var wg sync.WaitGroup
	workers := r.workers
	if workers > len(jobs) {
		workers = len(jobs)
	}
	wg.Add(workers)
	for i := 0; i < workers; i++ {
		go func() {
			defer wg.Done()
			verifier := crypto.NewVerifier()
			defer verifier.Close()
			for index := range next {
				job := jobs[index]
				job.options.Verifier = verifier
				start := time.Now()
				errs[index] = script.VerifyTransactionInput(job.tx, job.inputIndex, job.options)
				atomic.AddInt64(&workerNanos, time.Since(start).Nanoseconds())
			}
		}()
	}
	for i := range jobs {
		next <- i
	}
	close(next)
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			return &scriptFailure{job: jobs[i], err: err}, time.Duration(workerNanos)
		}
	}
	return nil, time.Duration(workerNanos)
}
