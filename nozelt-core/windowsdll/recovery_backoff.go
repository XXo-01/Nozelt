//go:build windows

package main

import "time"

// Retry forever while the user still wants the tunnel, without a busy loop.
type recoveryBackoff struct {
	failures uint
	next     time.Time
}

func (b *recoveryBackoff) ready(now time.Time) bool { return !now.Before(b.next) }
func (b *recoveryBackoff) reset()                   { b.failures = 0; b.next = time.Time{} }
func (b *recoveryBackoff) failed(now time.Time) {
	if b.failures < 5 {
		b.failures++
	}
	b.next = now.Add(time.Second * time.Duration(1<<b.failures))
}
