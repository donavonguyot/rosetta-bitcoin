package connect

import (
	"sort"
	"time"
)

type TimingSummary struct {
	TotalMillis       int64            `json:"total_ms"`
	StageTotalsMillis map[string]int64 `json:"stage_totals_ms"`
	SlowBlocks        []SlowBlock      `json:"slow_blocks"`
}

type SlowBlock struct {
	Height            int            `json:"height"`
	Millis            int64          `json:"ms"`
	TxCount           int            `json:"tx_count,omitempty"`
	VinCount          int            `json:"vin_count,omitempty"`
	VoutCount         int            `json:"vout_count,omitempty"`
	ScriptInputCount  int            `json:"script_input_count,omitempty"`
	InputShapeCounts  map[string]int `json:"input_shape_counts,omitempty"`
	OutputScriptTypes map[string]int `json:"output_script_types,omitempty"`
}

type timingCollector struct {
	start      time.Time
	stageNanos map[string]int64
	slowBlocks []SlowBlock
}

func newTimingCollector() *timingCollector {
	return &timingCollector{start: time.Now(), stageNanos: map[string]int64{}}
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
		SlowBlocks:        append([]SlowBlock{}, t.slowBlocks...),
	}
}
