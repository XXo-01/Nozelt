package core

import (
	"encoding/json"
	"testing"
	"time"
)

func startCoreForDelayTest(t *testing.T) {
	t.Helper()
	if IsRunning() {
		_ = Stop()
	}
	if err := Start(minimalYAML); err != nil {
		t.Fatalf("start delay-test core: %v", err)
	}
	t.Cleanup(func() { _ = Stop() })
}

func TestProxyDelaysUnknownProxy(t *testing.T) {
	startCoreForDelayTest(t)
	config := `{
  "mixed-port": 0,
  "mode": "rule",
  "proxies": [],
  "proxy-groups": [{"name":"PROXY","type":"select","proxies":["DIRECT"]}],
  "rules": ["MATCH,DIRECT"]
}`
	raw := TestProxyDelays(config, `["missing"]`, "", 500)
	var envelope delayEnvelope
	if err := json.Unmarshal([]byte(raw), &envelope); err != nil {
		t.Fatalf("invalid JSON: %v: %s", err, raw)
	}
	if !envelope.OK {
		t.Fatalf("unexpected envelope error: %s", envelope.Error)
	}
	if envelope.Results["missing"].Error != "proxy not found" {
		t.Fatalf("unexpected result: %#v", envelope.Results["missing"])
	}
}

func TestProxyDelaysRequireActiveVPN(t *testing.T) {
	if IsRunning() {
		_ = Stop()
	}
	config := `{
  "mixed-port": 0,
  "mode": "rule",
  "proxies": [],
  "proxy-groups": [{"name":"PROXY","type":"select","proxies":["DIRECT"]}],
  "rules": ["MATCH,DIRECT"]
}`
	raw := TestProxyDelays(config, `["missing"]`, "", 500)
	var envelope delayEnvelope
	if err := json.Unmarshal([]byte(raw), &envelope); err != nil {
		t.Fatalf("invalid JSON: %v: %s", err, raw)
	}
	if envelope.OK || envelope.Error != "delay tests require an active VPN" {
		t.Fatalf("inactive delay result = ok:%v error:%q", envelope.OK, envelope.Error)
	}
}

func TestLifecycleCancelsRegisteredDelayTests(t *testing.T) {
	startCoreForDelayTest(t)

	ctx, finish, running, _ := beginDelayTest(
		delayTestGeneration(),
		delayThroughActiveVPN,
	)
	if !running {
		t.Fatal("beginDelayTest rejected a running core")
	}
	finished := make(chan struct{})
	go func() {
		<-ctx.Done()
		finish()
		close(finished)
	}()

	CancelDelayTests()

	select {
	case <-finished:
	case <-time.After(time.Second):
		t.Fatal("registered delay test was not cancelled")
	}
}

func TestCancellationGenerationRejectsLateRegistration(t *testing.T) {
	startCoreForDelayTest(t)
	generationBeforeParse := delayTestGeneration()

	// Models a large config still being parsed while the UI moves to the
	// background. Cancellation sees no registered worker yet, but the stale
	// parse must not be allowed to register network work afterwards.
	CancelDelayTests()
	_, finish, running, _ := beginDelayTest(
		generationBeforeParse,
		delayThroughActiveVPN,
	)
	finish()
	if running {
		t.Fatal("delay test registered after its cancellation generation")
	}
}

func TestProxyDelaysOfflineWhileStopped(t *testing.T) {
	if IsRunning() {
		_ = Stop()
	}
	SetSocketProtector(nil)
	t.Cleanup(func() { SetSocketProtector(nil) })
	config := `{
  "mixed-port": 0,
  "mode": "rule",
  "dns": {
    "enable": true,
    "default-nameserver": ["https://1.1.1.1/dns-query"],
    "nameserver": ["https://1.1.1.1/dns-query"],
    "proxy-server-nameserver": ["https://1.1.1.1/dns-query"]
  },
  "proxies": [],
  "proxy-groups": [{"name":"PROXY","type":"select","proxies":["DIRECT"]}],
  "rules": ["MATCH,DIRECT"]
}`
	raw := TestProxyDelaysOffline(config, `["missing"]`, "", 500)
	var envelope delayEnvelope
	if err := json.Unmarshal([]byte(raw), &envelope); err != nil {
		t.Fatalf("invalid JSON: %v: %s", err, raw)
	}
	if !envelope.OK || envelope.Results["missing"].Error != "proxy not found" {
		t.Fatalf("unexpected offline result: %#v", envelope)
	}
}

func TestProxyDelaysOfflineRejectsFailClosedProtector(t *testing.T) {
	if IsRunning() {
		_ = Stop()
	}
	SetSocketProtector(func(int) bool { return true })
	t.Cleanup(func() { SetSocketProtector(nil) })
	raw := TestProxyDelaysOffline(minimalYAML, `["missing"]`, "", 500)
	var envelope delayEnvelope
	if err := json.Unmarshal([]byte(raw), &envelope); err != nil {
		t.Fatalf("invalid JSON: %v: %s", err, raw)
	}
	if envelope.OK || envelope.Error != "offline delay tests require a fully stopped VPN" {
		t.Fatalf("protected offline result = ok:%v error:%q", envelope.OK, envelope.Error)
	}
}

func TestProxyDelaysProtectedWithNativeCore(t *testing.T) {
	if IsRunning() {
		_ = Stop()
	}
	SetSocketProtector(func(int) bool { return true })
	t.Cleanup(func() { SetSocketProtector(nil) })
	config := `{
  "mixed-port": 0,
  "mode": "rule",
  "unified-delay": true,
  "dns": {
    "enable": true,
    "default-nameserver": ["https://1.1.1.1/dns-query"],
    "nameserver": ["https://1.1.1.1/dns-query"],
    "proxy-server-nameserver": ["https://1.1.1.1/dns-query"]
  },
  "proxies": [],
  "proxy-groups": [{"name":"PROXY","type":"select","proxies":["DIRECT"]}],
  "rules": ["MATCH,DIRECT"]
}`
	raw := TestProxyDelays(config, `["missing"]`, "", 500)
	var envelope delayEnvelope
	if err := json.Unmarshal([]byte(raw), &envelope); err != nil {
		t.Fatalf("invalid JSON: %v: %s", err, raw)
	}
	if !envelope.OK || envelope.Results["missing"].Error != "proxy not found" {
		t.Fatalf("unexpected native-core protected result: %#v", envelope)
	}
}

func TestStartCancelsRegisteredOfflineDelayTest(t *testing.T) {
	if IsRunning() {
		_ = Stop()
	}
	SetSocketProtector(nil)
	t.Cleanup(func() {
		if IsRunning() {
			_ = Stop()
		}
		SetSocketProtector(nil)
	})

	ctx, finish, accepted, _ := beginDelayTest(
		delayTestGeneration(),
		delayDirectWhileStopped,
	)
	if !accepted {
		t.Fatal("stopped core rejected an offline delay test")
	}
	finished := make(chan struct{})
	go func() {
		<-ctx.Done()
		finish()
		close(finished)
	}()

	if err := Start(minimalYAML); err != nil {
		t.Fatalf("start after offline delay test: %v", err)
	}
	select {
	case <-finished:
	case <-time.After(time.Second):
		t.Fatal("VPN start did not drain the offline delay test")
	}
}

func TestProxyDelaysAcceptsSubscriptionHTTPTestURL(t *testing.T) {
	startCoreForDelayTest(t)
	config := `{
  "mixed-port": 0,
  "mode": "rule",
  "proxies": [],
  "proxy-groups": [{"name":"PROXY","type":"select","proxies":["DIRECT"]}],
  "rules": ["MATCH,DIRECT"]
}`
	raw := TestProxyDelays(config, `["missing"]`, "http://example.com/probe", 500)
	var envelope delayEnvelope
	if err := json.Unmarshal([]byte(raw), &envelope); err != nil {
		t.Fatalf("invalid JSON: %v: %s", err, raw)
	}
	if !envelope.OK || envelope.Results["missing"].Error != "proxy not found" {
		t.Fatalf("HTTP URL result = %#v", envelope)
	}
}

func TestProxyDelaysAcceptsPerProxyTestURLs(t *testing.T) {
	startCoreForDelayTest(t)
	config := `{
  "mixed-port": 0,
  "mode": "rule",
  "proxies": [],
  "proxy-groups": [{"name":"PROXY","type":"select","proxies":["DIRECT"]}],
  "rules": ["MATCH,DIRECT"]
}`
	targets := `[{"name":"mobile","url":"http://cp.cloudflare.com/generate_204"},{"name":"wifi","url":"https://www.gstatic.com/generate_204"}]`
	raw := TestProxyDelays(config, targets, "", 500)
	var envelope delayEnvelope
	if err := json.Unmarshal([]byte(raw), &envelope); err != nil {
		t.Fatalf("invalid JSON: %v: %s", err, raw)
	}
	if !envelope.OK ||
		envelope.Results["mobile"].Error != "proxy not found" ||
		envelope.Results["wifi"].Error != "proxy not found" {
		t.Fatalf("per-proxy URL result = %#v", envelope)
	}
}

func TestProxyDelaysRejectsInvalidTestURL(t *testing.T) {
	config := `{
  "mixed-port": 0,
  "mode": "rule",
  "proxies": [],
  "proxy-groups": [{"name":"PROXY","type":"select","proxies":["DIRECT"]}],
  "rules": ["MATCH,DIRECT"]
}`
	raw := TestProxyDelays(config, `[{"name":"missing","url":"ftp://example.com/probe"}]`, "", 500)
	var envelope delayEnvelope
	if err := json.Unmarshal([]byte(raw), &envelope); err != nil {
		t.Fatalf("invalid JSON: %v: %s", err, raw)
	}
	if envelope.OK || envelope.Error != "delay test URL must be a valid HTTP(S) URL" {
		t.Fatalf("invalid URL result = ok:%v error:%q", envelope.OK, envelope.Error)
	}
}

func TestDelayProbeURLsRetryPrimaryAndProvideFallbacks(t *testing.T) {
	urls := delayProbeURLs("http://provider.example/check")
	if len(urls) != 4 {
		t.Fatalf("probe URL count = %d, want 4: %#v", len(urls), urls)
	}
	if urls[0] != "http://provider.example/check" || urls[2] != urls[0] {
		t.Fatalf("provider URL is not retried: %#v", urls)
	}
	if urls[1] == urls[0] || urls[3] == urls[0] || urls[1] == urls[3] {
		t.Fatalf("fallback URLs are not independent: %#v", urls)
	}
}

func TestRepresentativeDelayUsesLowerMedian(t *testing.T) {
	if got := representativeDelay([]int{310, 42}); got != 42 {
		t.Fatalf("two-sample representative delay = %d, want 42", got)
	}
	if got := representativeDelay([]int{310, 42, 65}); got != 65 {
		t.Fatalf("three-sample representative delay = %d, want 65", got)
	}
}

func TestParseConfigRejectsOversizedInputBeforeMihomo(t *testing.T) {
	_, err := parseConfig(string(make([]byte, maxConfigBytes+1)))
	if err == nil || err.Error() != "config exceeds the safe size limit" {
		t.Fatalf("oversized config error = %v", err)
	}
}
