package core

import (
	"errors"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/component/dialer"
)

type fakeRawConn struct {
	fd         uintptr
	controlErr error
}

func (c fakeRawConn) Control(callback func(uintptr)) error {
	if c.controlErr != nil {
		return c.controlErr
	}
	callback(c.fd)
	return nil
}

func (fakeRawConn) Read(func(uintptr) bool) error  { return nil }
func (fakeRawConn) Write(func(uintptr) bool) error { return nil }

func TestSocketProtectorAcceptsAndDetaches(t *testing.T) {
	t.Cleanup(func() { SetSocketProtector(nil) })
	var received int
	SetSocketProtector(func(fd int) bool {
		received = fd
		return true
	})

	if dialer.DefaultSocketHook == nil {
		t.Fatal("mihomo socket hook was not installed")
	}
	if err := protectRawSocket("udp", "ignored", fakeRawConn{fd: 42}); err != nil {
		t.Fatalf("protectRawSocket() = %v", err)
	}
	if received != 42 {
		t.Fatalf("protector received fd %d, want 42", received)
	}

	SetSocketProtector(nil)
	if dialer.DefaultSocketHook != nil {
		t.Fatal("mihomo socket hook remained installed after detach")
	}
}

func TestSocketProtectorFailsClosed(t *testing.T) {
	t.Cleanup(func() { SetSocketProtector(nil) })

	SetSocketProtector(func(int) bool { return false })
	if err := protectRawSocket("tcp", "ignored", fakeRawConn{fd: 7}); err == nil ||
		!strings.Contains(err.Error(), "rejected socket protection") {
		t.Fatalf("rejected protector error = %v", err)
	}

	SetSocketProtector(func(int) bool { panic("host callback failure") })
	if err := protectRawSocket("tcp", "ignored", fakeRawConn{fd: 8}); err == nil ||
		!strings.Contains(err.Error(), "callback failed") {
		t.Fatalf("panicking protector error = %v", err)
	}

	sentinel := errors.New("raw control failed")
	if err := protectRawSocket(
		"tcp",
		"ignored",
		fakeRawConn{controlErr: sentinel},
	); !errors.Is(err, sentinel) {
		t.Fatalf("raw control error = %v, want sentinel", err)
	}
}

func TestSocketProtectionStatusResetsOnInstall(t *testing.T) {
	SetSocketProtector(func(int) bool { return true })
	t.Cleanup(func() { SetSocketProtector(nil) })

	enabled, attempts, failures := socketProtectionStatus()
	if !enabled || attempts != 0 || failures != 0 {
		t.Fatalf("fresh protector status = (%v, %d, %d)", enabled, attempts, failures)
	}

	SetSocketProtector(nil)
	enabled, _, _ = socketProtectionStatus()
	if enabled {
		t.Fatal("socket protection still reported enabled after detach")
	}
}
