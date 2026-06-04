package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"rosettabitcoin/nodes/go/internal/connect"
)

func main() {
	datadir := flag.String("datadir", "./data-go", "native datadir")
	target := flag.Int("target", 2, "target height")
	progress := flag.Int("progress", 100, "progress interval")
	flag.Parse()
	summary, err := connect.Run(connect.Options{
		DataDir:  *datadir,
		Target:   *target,
		Progress: *progress,
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	payload, _ := json.MarshalIndent(summary, "", "  ")
	fmt.Println(string(payload))
	if !summary.ReachedTarget {
		os.Exit(2)
	}
}
