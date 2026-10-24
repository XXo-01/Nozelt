package core

import (
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"syscall"

	"github.com/metacubex/mihomo/component/dialer"
)

// SocketProtector excludes an outbound socket from Android's VpnService TUN.
// Android hosts install a callback backed by VpnService.protect(fd) before
// Start and remove it only after Stop has drained all mihomo transports.
type SocketProtector func(fd int) bool

var (
	socketProtectorMu  sync.RWMutex
	socketProtector    SocketProtector
	protectionAttempts atomic.Uint64
	protectionFailures atomic.Uint64
)

// SetSocketProtector installs the Android per-socket anti-loop callback.
// Passing nil restores mihomo's normal platform dialer. Callers must only
// replace this hook while the engine is stopped.
func SetSocketProtector(protector SocketProtector) {
	// Installing Android's protector marks the beginning of a fail-closed VPN
	// lifecycle. Drain explicit direct/offline probes before the global dialer
	// hook changes, so no socket can cross from one network mode into the other.
	current.mu.Lock()
	defer current.mu.Unlock()
	cancelAndWaitDelayTests()

	socketProtectorMu.Lock()
	defer socketProtectorMu.Unlock()

	socketProtector = protector
	if protector == nil {
		dialer.DefaultSocketHook = nil
		return
	}
	protectionAttempts.Store(0)
	protectionFailures.Store(0)
	dialer.DefaultSocketHook = protectRawSocket
}

func protectRawSocket(_ string, _ string, raw syscall.RawConn) error {
	protectionAttempts.Add(1)
	if raw == nil {
		protectionFailures.Add(1)
		return errors.New("nozelt core: socket protector received a nil connection")
	}

	var protectErr error
	controlErr := raw.Control(func(fd uintptr) {
		socketProtectorMu.RLock()
		defer socketProtectorMu.RUnlock()
		defer func() {
			if recovered := recover(); recovered != nil {
				protectErr = errors.New("nozelt core: socket protector callback failed")
			}
		}()

		if socketProtector == nil {
			protectErr = errors.New("nozelt core: socket protector is unavailable")
			return
		}
		if !socketProtector(int(fd)) {
			protectErr = errors.New("nozelt core: Android rejected socket protection")
		}
	})
	if controlErr != nil {
		protectionFailures.Add(1)
		return fmt.Errorf("nozelt core: access outbound socket: %w", controlErr)
	}
	if protectErr != nil {
		protectionFailures.Add(1)
	}
	return protectErr
}

// socketProtectionStatus is intentionally package-private: it is exposed only
// as aggregate diagnostics in Status, never as individual socket metadata.
func socketProtectionStatus() (enabled bool, attempts, failures uint64) {
	socketProtectorMu.RLock()
	enabled = socketProtector != nil
	socketProtectorMu.RUnlock()
	return enabled, protectionAttempts.Load(), protectionFailures.Load()
}
