// Package logger provides a callback-based logging facility used across
// nozelt-core. The host application (Kotlin via gomobile) supplies an
// implementation of the Logger interface; all internal packages route
// log messages through it instead of writing to stdout.
package logger

import (
	"sync"
)

// Log level constants. These are plain strings so they cross the gomobile
// boundary without translation and remain readable on the Kotlin side.
const (
	LevelDebug   = "debug"
	LevelInfo    = "info"
	LevelWarning = "warning"
	LevelError   = "error"
)

// Logger is the interface the host application implements. The signature is
// deliberately narrow so it satisfies gomobile's bind restrictions
// (only primitive types in method parameters).
type Logger interface {
	Log(level string, message string)
}

var (
	mu     sync.RWMutex
	active Logger
)

// Set installs the logger implementation supplied by the host. Passing nil
// disables logging.
func Set(logger Logger) {
	mu.Lock()
	active = logger
	mu.Unlock()
}

// Get returns the currently installed logger, or nil if none is set.
func Get() Logger {
	mu.RLock()
	defer mu.RUnlock()
	return active
}

// Emit forwards a message to the active logger if one is set. It is safe to
// call from any goroutine and from any package that imports logger. Exported
// because the mihomo log forwarder needs to emit with a level chosen at
// runtime rather than a hard-coded one of the helpers below.
func Emit(level, message string) {
	mu.RLock()
	l := active
	mu.RUnlock()
	if l == nil {
		return
	}
	l.Log(level, message)
}

// Debug, Info, Warn, Error are thin helpers so call sites do not repeat the
// level string. They no-op when no logger is installed.
func Debug(message string) { Emit(LevelDebug, message) }
func Info(message string)  { Emit(LevelInfo, message) }
func Warn(message string)  { Emit(LevelWarning, message) }
func Error(message string) { Emit(LevelError, message) }
