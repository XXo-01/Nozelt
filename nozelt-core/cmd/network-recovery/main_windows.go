//go:build windows

package main

import (
	"flag"
	"fmt"
	"github.com/nozelt/nozelt-core/networkguard"
	"os"
)

func main() {
	release := flag.Bool("release", false, "Remove only Nozelt's persistent network protection after explicit disconnect/crash")
	flag.Parse()
	if !*release {
		fmt.Println("Use --release as administrator to restore networking after a Nozelt crash. This removes only Nozelt filters.")
		return
	}
	if err := networkguard.Release(); err != nil {
		fmt.Fprintln(os.Stderr, "Nozelt network recovery failed:", err)
		os.Exit(1)
	}
	fmt.Println("Nozelt network protection released.")
}
