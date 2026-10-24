package core

import (
	"errors"
	"testing"
)

func TestProbeLiveConnectionRequiresRunningCore(t *testing.T) {
	if IsRunning() {
		_ = Stop()
	}
	if err := ProbeLiveConnection(500); !errors.Is(err, ErrNotRunning) {
		t.Fatalf("stopped probe error = %v, want ErrNotRunning", err)
	}
}

func TestProbeLiveConnectionReportsDeadPath(t *testing.T) {
	if IsRunning() {
		_ = Stop()
	}
	const rejectYAML = `
mode: rule
log-level: error
proxies: []
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - REJECT
rules:
  - MATCH,PROXY
`
	if err := Start(rejectYAML); err != nil {
		t.Fatalf("start: %v", err)
	}
	t.Cleanup(func() { _ = Stop() })
	if err := ProbeLiveConnection(1000); err == nil {
		t.Fatal("probe through REJECT succeeded, want failure")
	}
}

func TestProbeLiveConnectionMissingGroup(t *testing.T) {
	if IsRunning() {
		_ = Stop()
	}
	const noGroupYAML = `
mode: rule
log-level: error
proxies: []
rules:
  - MATCH,REJECT
`
	if err := Start(noGroupYAML); err != nil {
		t.Fatalf("start: %v", err)
	}
	t.Cleanup(func() { _ = Stop() })
	if err := ProbeLiveConnection(500); err == nil {
		t.Fatal("probe without PROXY group succeeded, want failure")
	}
}
