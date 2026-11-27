//go:build !android

package main

import (
	"core"
	"fmt"
	"os"
)

func main() {
	args := os.Args
	if len(args) == 2 && args[1] == "--core-info" {
		if err := writeCoreInfo(os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if len(args) <= 1 {
		fmt.Fprintln(os.Stderr, "Arguments error")
		os.Exit(1)
	}
	go core.ExitOnTermination()
	core.StartServer(args[1])
}
