//go:build android

package core

import "runtime/debug"

// The Go runtime shares the app process with Flutter. A soft limit makes the
// collector work harder before a large subscription inflates the heap far
// enough for Android to kill the VPN process. It is not a hard cap.
func init() {
	debug.SetMemoryLimit(256 << 20)
}

// releaseMemory returns freed heap pages to Android after a session ends.
func releaseMemory() { debug.FreeOSMemory() }
