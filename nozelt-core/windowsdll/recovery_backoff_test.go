//go:build windows

package main

import (
	"testing"
	"time"
)

func TestRecoveryRetriesBeyondThreeFailures(t *testing.T) {
	b := recoveryBackoff{}
	now := time.Unix(1, 0)
	for i := 0; i < 100; i++ {
		if !b.ready(now) {
			t.Fatal("retry was abandoned")
		}
		b.failed(now)
		if b.ready(now) || b.next.Sub(now) > 32*time.Second {
			t.Fatal("unsafe retry cadence")
		}
		now = b.next
	}
	b.reset()
	if !b.ready(time.Unix(1, 0)) {
		t.Fatal("network change does not reset delay")
	}
}
