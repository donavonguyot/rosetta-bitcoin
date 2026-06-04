package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"rosettabitcoin/nodes/go/internal/scriptcorpus"
)

func main() {
	manifest := flag.String("manifest", "", "Shared script corpus manifest")
	resultPath := flag.String("result-path", "", "result JSON path")
	fixtureID := flag.String("fixture-id", "", "single fixture id")
	flag.Parse()
	summary, err := scriptcorpus.Run(*manifest, *resultPath, *fixtureID)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	payload, _ := json.MarshalIndent(summary, "", "  ")
	fmt.Println(string(payload))
	if summary.Failed != 0 {
		os.Exit(1)
	}
}
