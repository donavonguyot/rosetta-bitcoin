package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"rosettabitcoin/nodes/go/internal/repo"
	"rosettabitcoin/nodes/go/internal/storage"
)

func main() {
	datadir := flag.String("datadir", "./data-go-proof", "native proof datadir")
	resultPath := flag.String("result-path", "", "proof result path")
	flag.Parse()
	if *resultPath == "" {
		root, err := repo.Root()
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		*resultPath = filepath.Join(root, "Shared", "conformance", "results", "go_storage_gate_"+time.Now().UTC().Format("2006-01-02")+".json")
	}
	doc, err := storage.RunProof(*datadir, *resultPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	summary := map[string]any{
		"validated_height": doc.ValidatedHeight,
		"result":           "passed",
		"result_path":      *resultPath,
	}
	payload, _ := json.MarshalIndent(summary, "", "  ")
	fmt.Println(string(payload))
}
