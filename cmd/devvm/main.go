package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/addiberra/multipass-devenv/internal/create"
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	commandArgs := args
	if len(commandArgs) > 0 && commandArgs[0] == "create" {
		commandArgs = commandArgs[1:]
	}

	fs := flag.NewFlagSet("create", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	configPath := fs.String("config", "devvm.yaml", "Path to devvm.yaml")
	if err := fs.Parse(commandArgs); err != nil {
		return 2
	}
	if fs.NArg() != 0 {
		fmt.Fprintf(os.Stderr, "unexpected arguments: %v\n", fs.Args())
		return 2
	}

	if err := create.Run(*configPath, os.Stdout, os.Stderr); err != nil {
		fmt.Fprintf(os.Stderr, "create failed: %v\n", err)
		return 1
	}
	return 0
}
