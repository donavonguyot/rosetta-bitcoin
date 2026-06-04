package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"rosettabitcoin/nodes/go/internal/blocker"
	"rosettabitcoin/nodes/go/internal/storage"
)

func main() {
	height := flag.Int("height", 0, "block height")
	txid := flag.String("txid", "", "transaction id")
	input := flag.Int("input", 0, "input index")
	datadir := flag.String("datadir", "./data-go", "native datadir")
	flag.Parse()
	meta, err := storage.ReadMetadata(*datadir)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	doc := blocker.Empty(*height, *input, *txid)
	if meta.CurrentBlocker != nil {
		doc = blocker.FromCurrent(meta.CurrentBlocker, *height, *input, *txid)
	}
	payload, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println(string(payload))
}
