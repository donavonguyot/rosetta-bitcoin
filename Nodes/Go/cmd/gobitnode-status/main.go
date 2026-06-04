package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"rosettabitcoin/nodes/go/internal/status"
)

func main() {
	datadir := flag.String("datadir", "./data-go", "native datadir")
	flag.Parse()
	doc, err := status.Build(*datadir)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	payload, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println(string(payload))
}
