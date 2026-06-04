package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"rosettabitcoin/nodes/go/internal/refsync"
)

func main() {
	datadir := flag.String("datadir", "./data-go", "native datadir")
	target := flag.Int("target", 10000, "target height")
	rpcURL := flag.String("rpc-url", "http://127.0.0.1:48332", "Bitcoin Core RPC URL")
	rpcUser := flag.String("rpc-user", "rosetta", "Bitcoin Core RPC user")
	rpcPassword := flag.String("rpc-password", "rosetta-dev-only", "Bitcoin Core RPC password")
	progress := flag.Int("progress", 1000, "progress interval")
	flag.Parse()
	summary, err := refsync.Run(refsync.Options{
		DataDir:  *datadir,
		Target:   *target,
		RPCURL:   *rpcURL,
		RPCUser:  *rpcUser,
		RPCPass:  *rpcPassword,
		Progress: *progress,
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	payload, _ := json.MarshalIndent(summary, "", "  ")
	fmt.Println(string(payload))
}
