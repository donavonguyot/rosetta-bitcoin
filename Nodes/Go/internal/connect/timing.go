package connect

import (
	"sort"
	"time"
)

type TimingSummary struct {
	TotalMillis       int64            `json:"total_ms"`
	StageTotalsMillis map[string]int64 `json:"stage_totals_ms"`
	UTXOLookupCount   int64            `json:"utxo_lookup_count,omitempty"`
	UTXOKeyBytes      int64            `json:"utxo_key_bytes,omitempty"`
	UTXOValueBytes    int64            `json:"utxo_value_bytes,omitempty"`
	CreatedUTXOs      int64            `json:"created_utxos,omitempty"`
	SpentExternal     int64            `json:"spent_external,omitempty"`
	SameBlockSpends   int64            `json:"same_block_spends,omitempty"`
	RunnerBatches     int64            `json:"runner_batches,omitempty"`
	TxCount           int64            `json:"tx_count,omitempty"`
	InputCount        int64            `json:"input_count,omitempty"`
	ScriptJobs        int64            `json:"script_jobs,omitempty"`
	ScriptThreads     int              `json:"script_threads,omitempty"`
	SlowBlocks        []SlowBlock      `json:"slow_blocks"`
}

type SlowBlock struct {
	Height                  int            `json:"height"`
	Millis                  int64          `json:"ms"`
	TxCount                 int            `json:"tx_count,omitempty"`
	VinCount                int            `json:"vin_count,omitempty"`
	VoutCount               int            `json:"vout_count,omitempty"`
	ScriptInputCount        int            `json:"script_input_count,omitempty"`
	InputShapeCounts        map[string]int `json:"input_shape_counts,omitempty"`
	OutputScriptTypes       map[string]int `json:"output_script_types,omitempty"`
	SpentPrevoutScriptTypes map[string]int `json:"spent_prevout_script_types,omitempty"`
}

type timingCollector struct {
	start      time.Time
	stageNanos map[string]int64
	counters   map[string]int64
	slowBlocks []SlowBlock
}

func newTimingCollector() *timingCollector {
	return &timingCollector{start: time.Now(), stageNanos: map[string]int64{}, counters: map[string]int64{}}
}

func (t *timingCollector) measure(stage string, fn func() error) error {
	start := time.Now()
	err := fn()
	t.stageNanos[stage] += time.Since(start).Nanoseconds()
	return err
}

func (t *timingCollector) measureValue(stage string, fn func() error) error {
	return t.measure(stage, fn)
}

func (t *timingCollector) addStage(stage string, duration time.Duration) {
	t.stageNanos[stage] += duration.Nanoseconds()
}

func (t *timingCollector) addMillis(stage string, millis int64) {
	t.stageNanos[stage] += millis * int64(time.Millisecond)
}

func (t *timingCollector) addCount(name string, count int64) {
	t.counters[name] += count
}

func (t *timingCollector) setCount(name string, count int64) {
	t.counters[name] = count
}

func (t *timingCollector) recordBlock(height int, duration time.Duration, shape SlowBlock) {
	shape.Height = height
	shape.Millis = duration.Milliseconds()
	t.slowBlocks = append(t.slowBlocks, shape)
	sort.Slice(t.slowBlocks, func(i, j int) bool {
		return t.slowBlocks[i].Millis > t.slowBlocks[j].Millis
	})
	if len(t.slowBlocks) > 10 {
		t.slowBlocks = t.slowBlocks[:10]
	}
}

func (t *timingCollector) summary() TimingSummary {
	stages := make(map[string]int64, len(t.stageNanos))
	for stage, nanos := range t.stageNanos {
		stages[stage] = nanos / int64(time.Millisecond)
	}
	return TimingSummary{
		TotalMillis:       time.Since(t.start).Milliseconds(),
		StageTotalsMillis: stages,
		UTXOLookupCount:   t.counters["utxo_lookup_count"],
		UTXOKeyBytes:      t.counters["utxo_key_bytes"],
		UTXOValueBytes:    t.counters["utxo_value_bytes"],
		CreatedUTXOs:      t.counters["created_utxos"],
		SpentExternal:     t.counters["spent_external"],
		SameBlockSpends:   t.counters["same_block_spends"],
		RunnerBatches:     t.counters["runner_batches"],
		TxCount:           t.counters["tx_count"],
		InputCount:        t.counters["input_count"],
		ScriptJobs:        t.counters["script_jobs"],
		ScriptThreads:     int(t.counters["script_threads"]),
		SlowBlocks:        append([]SlowBlock{}, t.slowBlocks...),
	}
}
