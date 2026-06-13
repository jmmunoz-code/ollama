//go:build linux && arm64

package main

import (
	"os"
	"syscall"
)

func main() {
	if len(os.Args) != 1 {
		os.Exit(1)
	}

	os.Clearenv()
	syscall.Sync()

	if err := os.WriteFile("/proc/sys/vm/drop_caches", []byte("3"), 0o200); err != nil {
		os.Exit(1)
	}
}
