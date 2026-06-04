package main

import (
	"fmt"
	"os"
	"os/exec"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Println("gobitnode scaffold: use status, storage-proof, sync, connect, script-corpus, local-reference-proof, or blocker-inspect subcommands in Docker")
		return
	}
	switch os.Args[1] {
	case "status":
		run("gobitnode-status", os.Args[2:]...)
	case "storage-proof":
		run("gobitnode-storage-proof", os.Args[2:]...)
	case "sync":
		run("gobitnode-sync", os.Args[2:]...)
	case "connect":
		run("gobitnode-connect", os.Args[2:]...)
	case "script-corpus":
		run("gobitnode-script-corpus", os.Args[2:]...)
	case "blocker-inspect":
		run("gobitnode-blocker-inspect", os.Args[2:]...)
	case "local-reference-proof":
		run("gobitnode-local-reference-proof", os.Args[2:]...)
	default:
		fmt.Fprintf(os.Stderr, "unknown subcommand: %s\n", os.Args[1])
		os.Exit(2)
	}
}

func run(name string, args ...string) {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin
	if err := cmd.Run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
