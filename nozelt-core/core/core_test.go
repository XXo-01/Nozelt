package core

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/listener"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/tunnel"
)

// minimalYAML is the smallest config that exercises the full Start path
// without binding to any inbound ports. Leaving all port fields off means
// the listener post-check has nothing to verify, so Start succeeds without
// us racing the OS for free TCP ports.
const minimalYAML = `
mode: rule
log-level: error
proxies: []
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - DIRECT
rules:
  - MATCH,PROXY
`

const fakeDNSYAML = `
mode: rule
log-level: error
dns:
  enable: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.0/15
  nameserver:
    - 1.1.1.1
proxies: []
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - DIRECT
rules:
  - MATCH,PROXY
`

// TestParseConfig_Valid confirms the wrapper accepts a well-formed YAML
// and surfaces the mihomo *config.Config it produced.
func TestParseConfig_Valid(t *testing.T) {
	p, err := parseConfig(minimalYAML)
	if err != nil {
		t.Fatalf("parseConfig(minimalYAML) = err: %v", err)
	}
	if p == nil || p.cfg == nil {
		t.Fatal("parseConfig returned nil parsedConfig or nil cfg")
	}
	if p.cfg.General == nil {
		t.Fatal("parsed cfg.General is nil")
	}
	if got, want := p.cfg.General.Mode.String(), "rule"; got != want {
		t.Errorf("Mode = %q, want %q", got, want)
	}
}

// TestParseConfig_Empty makes sure we reject empty input explicitly rather
// than letting mihomo's parser emit a confusing diagnostic.
func TestParseConfig_Empty(t *testing.T) {
	if _, err := parseConfig(""); err == nil {
		t.Fatal("parseConfig(\"\") = nil err, want non-nil")
	}
	if _, err := parseConfig("   \n\t  "); err == nil {
		t.Fatal("parseConfig(whitespace) = nil err, want non-nil")
	}
}

// TestParseConfig_Invalid checks that malformed input produces a deterministic
// error without echoing credential-bearing parser context.
func TestParseConfig_Invalid(t *testing.T) {
	const marker = "nozelt-super-secret-config-marker"
	_, err := parseConfig("password: " + marker + "\ninvalid: [")
	if err == nil {
		t.Fatal("parseConfig(garbage) = nil err, want non-nil")
	}
	if err.Error() != "mihomo parse failed" {
		t.Errorf("error = %q, want deterministic secret-free message", err.Error())
	}
	if strings.Contains(err.Error(), marker) {
		t.Fatalf("parse error echoed credential marker: %q", err.Error())
	}
}

func TestParseConfig_DisablesMihomoDiskProfile(t *testing.T) {
	parsed, err := parseConfig(`
mixed-port: 7890
profile:
  store-selected: true
  store-fake-ip: true
`)
	if err != nil {
		t.Fatalf("parseConfig returned error: %v", err)
	}
	if parsed.cfg.Profile.StoreSelected {
		t.Fatal("store-selected must be disabled by the Nozelt core")
	}
	if parsed.cfg.Profile.StoreFakeIP {
		t.Fatal("store-fake-ip must be disabled by the Nozelt core")
	}
}

func TestParseConfigRejectsLocalServicesBesideTun(t *testing.T) {
	for name, injected := range map[string]string{
		"mixed proxy":         "mixed-port: 7890\n",
		"dns listener":        "dns:\n  enable: true\n  listen: 0.0.0.0:1053\n",
		"external controller": "external-controller: 127.0.0.1:9090\n",
	} {
		t.Run(name, func(t *testing.T) {
			config := injected + tunYAML
			if _, err := parseConfig(config); err == nil ||
				!strings.Contains(err.Error(), "must not expose local inbound") {
				t.Fatalf("parseConfig error = %v, want TUN privacy rejection", err)
			}
		})
	}
}

// TestStartStop runs the full lifecycle once with no inbound ports so the
// test is hermetic — no risk of colliding with another listener on CI.
// Verifies the wrapper's idempotency contracts on both ends.
func TestStartStop(t *testing.T) {
	if IsRunning() {
		// Defensive: another test in the same package may have left state.
		_ = Stop()
	}

	if err := Start(minimalYAML); err != nil {
		t.Fatalf("Start = %v, want nil", err)
	}
	if !IsRunning() {
		t.Fatal("IsRunning = false after successful Start")
	}

	// Second Start without a Stop must surface ErrAlreadyRunning.
	if err := Start(minimalYAML); err != ErrAlreadyRunning {
		t.Errorf("second Start = %v, want ErrAlreadyRunning", err)
	}

	if err := Stop(); err != nil {
		t.Fatalf("Stop = %v, want nil", err)
	}
	if IsRunning() {
		t.Fatal("IsRunning = true after Stop")
	}
	if len(tunnel.Proxies()) != 0 || len(tunnel.Providers()) != 0 ||
		len(tunnel.Rules()) != 0 || len(tunnel.RuleProviders()) != 0 ||
		len(tunnel.Listeners()) != 0 {
		t.Fatal("mihomo process-global config references remained after Stop")
	}

	// Second Stop must surface ErrNotRunning.
	if err := Stop(); err != ErrNotRunning {
		t.Errorf("second Stop = %v, want ErrNotRunning", err)
	}
}

func TestStopForRestartPreservesFakeDNSUntilReplacementOrFinalStop(t *testing.T) {
	_ = Stop()
	if err := Start(fakeDNSYAML); err != nil {
		t.Fatalf("Start(fake DNS) = %v", err)
	}

	// Model an application reusing a just-returned synthetic DNS answer while
	// Android replaces the TUN/profile generation.
	fakeIP := netip.MustParseAddr("198.18.0.42")
	resolver.InsertHostByIP(fakeIP, "restart.example")
	if err := StopForRestart(); err != nil {
		t.Fatalf("StopForRestart = %v", err)
	}
	if IsRunning() {
		t.Fatal("core still running after StopForRestart")
	}
	if host, ok := resolver.FindHostByIP(fakeIP); !ok || host != "restart.example" {
		t.Fatalf("retained FakeDNS mapping = %q, %v", host, ok)
	}

	if err := Start(fakeDNSYAML); err != nil {
		t.Fatalf("replacement Start = %v", err)
	}
	if host, ok := resolver.FindHostByIP(fakeIP); !ok || host != "restart.example" {
		t.Fatalf("replacement lost FakeDNS mapping = %q, %v", host, ok)
	}
	if err := StopForRestart(); err != nil {
		t.Fatalf("second StopForRestart = %v", err)
	}
	// A final Stop must clean a mapper retained after an unsuccessful or
	// cancelled replacement even though the core is already idle.
	if err := Stop(); err != nil {
		t.Fatalf("final Stop after technical stop = %v", err)
	}
	if resolver.DefaultHostMapper != nil {
		t.Fatal("final Stop retained the FakeDNS mapper")
	}
	if err := Stop(); err != ErrNotRunning {
		t.Fatalf("second final Stop = %v, want ErrNotRunning", err)
	}
}

func TestTechnicalRestartDoesNotCloneFakeDNSAcrossRanges(t *testing.T) {
	_ = Stop()
	if err := Start(fakeDNSYAML); err != nil {
		t.Fatalf("Start(fake DNS) = %v", err)
	}
	fakeIP := netip.MustParseAddr("198.18.0.43")
	resolver.InsertHostByIP(fakeIP, "old-range.example")
	if err := StopForRestart(); err != nil {
		t.Fatalf("StopForRestart = %v", err)
	}

	replacement := strings.Replace(
		fakeDNSYAML,
		"fake-ip-range: 198.18.0.0/15",
		"fake-ip-range: 198.19.0.0/16",
		1,
	)
	if err := Start(replacement); err != nil {
		t.Fatalf("Start(replacement range) = %v", err)
	}
	t.Cleanup(func() { _ = Stop() })
	if host, ok := resolver.FindHostByIP(fakeIP); ok {
		t.Fatalf("old-range FakeDNS mapping survived as %q", host)
	}
}

func TestFailedInitialApplyLeavesNoMihomoGlobalState(t *testing.T) {
	_ = Stop()
	occupied, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve listener: %v", err)
	}
	defer occupied.Close()
	port := occupied.Addr().(*net.TCPAddr).Port
	config := fmt.Sprintf("mixed-port: %d\n%s", port, minimalYAML)

	if err := Start(config); err == nil {
		_ = Stop()
		t.Fatal("Start on occupied mixed port unexpectedly succeeded")
	}
	if IsRunning() {
		t.Fatal("failed initial apply left core marked running")
	}
	if len(tunnel.Proxies()) != 0 || len(tunnel.Providers()) != 0 ||
		len(tunnel.Rules()) != 0 || len(tunnel.RuleProviders()) != 0 ||
		len(tunnel.Listeners()) != 0 {
		t.Fatal("failed initial apply retained mihomo process-global config")
	}
	if resolver.DefaultResolver != nil || resolver.DefaultHostMapper != nil ||
		resolver.DefaultService != nil {
		t.Fatal("failed initial apply retained resolver state")
	}
	if ports := listener.GetPorts(); ports.MixedPort != 0 {
		t.Fatalf("failed initial apply retained mixed listener on %d", ports.MixedPort)
	}
}

func TestSelectProxy(t *testing.T) {
	if IsRunning() {
		_ = Stop()
	}
	if err := Start(minimalYAML); err != nil {
		t.Fatalf("Start = %v", err)
	}
	t.Cleanup(func() { _ = Stop() })

	if err := SelectProxy("PROXY", "DIRECT"); err != nil {
		t.Fatalf("SelectProxy(DIRECT) = %v", err)
	}
	if err := SelectProxy("PROXY", "missing"); err == nil {
		t.Fatal("SelectProxy(missing) unexpectedly succeeded")
	}
}

func TestRulesOnlyReloadPreservesSelectedProxy(t *testing.T) {
	const config = `
mode: rule
log-level: error
proxies:
  - name: Primary
    type: direct
  - name: Backup
    type: direct
proxy-groups:
  - name: PROXY
    type: select
    proxies: [Primary, Backup]
rules:
  - MATCH,PROXY
`
	if IsRunning() {
		_ = Stop()
	}
	if err := Start(config); err != nil {
		t.Fatalf("Start = %v", err)
	}
	t.Cleanup(func() { _ = Stop() })
	if err := SelectProxy("PROXY", "Backup"); err != nil {
		t.Fatalf("SelectProxy = %v", err)
	}

	reloaded := strings.Replace(
		config,
		"  - MATCH,PROXY",
		"  - DOMAIN-SUFFIX,example.test,DIRECT\n  - MATCH,PROXY",
		1,
	)
	if err := ReloadConfig(reloaded); err != nil {
		t.Fatalf("ReloadConfig = %v", err)
	}
	selector, ok := tunnel.Proxies()["PROXY"].Adapter().(interface{ Now() string })
	if !ok {
		t.Fatal("PROXY adapter does not expose its current selection")
	}
	if got := selector.Now(); got != "Backup" {
		t.Fatalf("selection after rules reload = %q, want Backup", got)
	}
}

func TestFailedReloadKeepsLifecycleRecoverable(t *testing.T) {
	if IsRunning() {
		_ = Stop()
	}
	if err := Start(minimalYAML); err != nil {
		t.Fatalf("Start = %v", err)
	}
	t.Cleanup(func() { _ = Stop() })

	if err := ReloadConfig(tunYAML); err == nil {
		t.Fatal("TUN reload without fd unexpectedly succeeded")
	}
	if !IsRunning() {
		t.Fatal("failed reload made the lifecycle un-stoppable")
	}
	if err := ReloadConfig(minimalYAML); err != nil {
		t.Fatalf("rollback reload = %v", err)
	}
}

func TestProxySignatureIgnoresRulesButTracksCredentials(t *testing.T) {
	base := `{
  "proxies":[{"name":"node","type":"http","server":"example.com","port":443,"password":"one"}],
  "proxy-groups":[{"name":"PROXY","type":"select","proxies":["node"]}],
  "rules":["MATCH,PROXY"]
}`
	rulesChanged := `{
  "rules":["DOMAIN-SUFFIX,example.org,DIRECT","MATCH,PROXY"],
  "proxy-groups":[{"proxies":["node"],"type":"select","name":"PROXY"}],
  "proxies":[{"password":"one","port":443,"server":"example.com","type":"http","name":"node"}]
}`
	credentialsChanged := strings.Replace(base, `"password":"one"`, `"password":"two"`, 1)

	first, err := proxyConfigSignature([]byte(base))
	if err != nil {
		t.Fatalf("base signature: %v", err)
	}
	second, err := proxyConfigSignature([]byte(rulesChanged))
	if err != nil {
		t.Fatalf("rules signature: %v", err)
	}
	third, err := proxyConfigSignature([]byte(credentialsChanged))
	if err != nil {
		t.Fatalf("credential signature: %v", err)
	}
	if first != second {
		t.Fatal("rules-only edit unexpectedly changed proxy signature")
	}
	if first == third {
		t.Fatal("credential edit did not change proxy signature")
	}
}

func TestProxySignatureIgnoresLiveSelectOrdering(t *testing.T) {
	first := `{
  "proxies":[],
  "proxy-groups":[{"name":"PROXY","type":"select","proxies":["Alpha","Beta","DIRECT"]}]
}`
	second := `{
  "proxies":[],
  "proxy-groups":[{"name":"PROXY","type":"select","proxies":["Beta","Alpha","DIRECT"]}]
}`

	left, err := proxyConfigSignature([]byte(first))
	if err != nil {
		t.Fatalf("first signature: %v", err)
	}
	right, err := proxyConfigSignature([]byte(second))
	if err != nil {
		t.Fatalf("second signature: %v", err)
	}
	if left != right {
		t.Fatal("selected-first ordering unexpectedly changed proxy signature")
	}
}

func TestRecoverNetworkPreservesSelectedProxy(t *testing.T) {
	const config = `
mode: rule
log-level: error
proxies:
  - name: Primary
    type: direct
  - name: Backup
    type: direct
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - Primary
      - Backup
rules:
  - MATCH,PROXY
`
	if IsRunning() {
		_ = Stop()
	}
	if err := Start(config); err != nil {
		t.Fatalf("Start = %v", err)
	}
	t.Cleanup(func() { _ = Stop() })
	if err := SelectProxy("PROXY", "Backup"); err != nil {
		t.Fatalf("SelectProxy(Backup) = %v", err)
	}
	if err := RecoverNetwork(); err != nil {
		t.Fatalf("RecoverNetwork = %v", err)
	}
	proxy, ok := tunnel.Proxies()["PROXY"]
	if !ok {
		t.Fatal("PROXY selector missing after recovery")
	}
	selector, ok := proxy.Adapter().(interface{ Now() string })
	if !ok {
		t.Fatal("PROXY adapter does not expose its current selection")
	}
	if got := selector.Now(); got != "Backup" {
		t.Fatalf("selection after recovery = %q, want Backup", got)
	}
}

// TestStatusJSON_Shape makes sure the JSON Status renders with the keys
// the Flutter/Kotlin side expects, both when idle and when running.
func TestStatusJSON_Shape(t *testing.T) {
	if IsRunning() {
		_ = Stop()
	}

	// Idle.
	var idle map[string]any
	if err := json.Unmarshal([]byte(GetStatusJSON()), &idle); err != nil {
		t.Fatalf("idle Status JSON: %v", err)
	}
	for _, key := range []string{
		"running", "uptimeSeconds", "mihomoVersion", "nozeltCoreVersion",
		"mode", "listeners", "connectionsCount", "tun",
	} {
		if _, ok := idle[key]; !ok {
			t.Errorf("idle Status missing key %q", key)
		}
	}
	if idle["running"].(bool) {
		t.Error("idle Status.running = true, want false")
	}
	if tun, ok := idle["tun"].(map[string]any); !ok {
		t.Error("idle Status.tun is not an object")
	} else if tun["enabled"].(bool) {
		t.Error("idle Status.tun.enabled = true, want false")
	}

	// Running.
	if err := Start(minimalYAML); err != nil {
		t.Fatalf("Start = %v", err)
	}
	defer func() { _ = Stop() }()

	var running map[string]any
	if err := json.Unmarshal([]byte(GetStatusJSON()), &running); err != nil {
		t.Fatalf("running Status JSON: %v", err)
	}
	if !running["running"].(bool) {
		t.Error("running Status.running = false, want true")
	}
	if running["mode"].(string) != "rule" {
		t.Errorf("running Status.mode = %q, want %q", running["mode"], "rule")
	}
	listeners, ok := running["listeners"].(map[string]any)
	if !ok {
		t.Fatal("running Status.listeners is not an object")
	}
	for _, key := range []string{"mixedPort", "httpPort", "socksPort", "redirPort", "tproxyPort"} {
		if _, ok := listeners[key]; !ok {
			t.Errorf("running Status.listeners missing key %q", key)
		}
	}
}

func TestMihomoVersionReportsModuleRelease(t *testing.T) {
	if got, want := MihomoVersion(), "1.19.32"; got != want {
		t.Fatalf("MihomoVersion() = %q, want embedded module release %q", got, want)
	}
	goMod, err := os.ReadFile("../go.mod")
	if err != nil {
		t.Fatalf("read go.mod: %v", err)
	}
	if want := "github.com/metacubex/mihomo v" + MihomoVersion(); !bytes.Contains(goMod, []byte(want)) {
		t.Fatalf("go.mod does not contain pinned display version %q", want)
	}
}

// tunYAML enables the TUN inbound so we can exercise the fd guard and the
// tun-section parsing. The stack is gvisor (mihomo's default) and auto-route
// is off because on Android the VpnService owns routing, not sing-tun.
const tunYAML = `
mode: rule
log-level: error
tun:
  enable: true
  stack: gvisor
  dns-hijack:
    - any:53
  auto-route: false
  auto-detect-interface: true
proxies: []
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - DIRECT
rules:
  - MATCH,PROXY
`

// TestParseConfig_Tun confirms the tun: section round-trips into the parsed
// config so the fd-injection path in applyConfig has real fields to stamp.
func TestParseConfig_Tun(t *testing.T) {
	p, err := parseConfig(tunYAML)
	if err != nil {
		t.Fatalf("parseConfig(tunYAML) = err: %v", err)
	}
	if !p.cfg.General.Tun.Enable {
		t.Error("cfg.General.Tun.Enable = false, want true")
	}
	// mihomo's raw Stack.String() is display-cased; parsing lowercases input.
	if got := p.cfg.General.Tun.Stack.String(); got != "gVisor" {
		t.Errorf("cfg.General.Tun.Stack = %q, want %q", got, "gVisor")
	}
	// The parsed config must NOT carry a descriptor yet — Go injects it from
	// SetTunFd at apply time, never from the YAML.
	if got := p.cfg.General.Tun.FileDescriptor; got != 0 {
		t.Errorf("parsed Tun.FileDescriptor = %d, want 0 (injected later)", got)
	}
}

// TestStart_TunWithoutFd asserts the hard guard: a TUN-enabled config with no
// descriptor set must fail Start (otherwise sing-tun would try to open its
// own device and hang/error on non-rooted Android), and must not leave the
// engine running.
func TestStart_TunWithoutFd(t *testing.T) {
	if IsRunning() {
		_ = Stop()
	}
	if err := SetTunFd(0); err != nil { // ensure no stale fd from another test
		t.Fatalf("SetTunFd(0) = %v", err)
	}

	err := Start(tunYAML)
	if err == nil {
		_ = Stop()
		t.Fatal("Start(tunYAML) with no fd = nil, want error")
	}
	if !strings.Contains(err.Error(), "tun fd") {
		t.Errorf("error = %q, want mention of 'tun fd'", err.Error())
	}
	if IsRunning() {
		t.Error("engine is running after a failed TUN Start")
	}
}

// TestSetTunFd_Validation covers the descriptor setter's contract: negatives
// rejected, zero (clear) and positive accepted.
func TestSetTunFd_Validation(t *testing.T) {
	if err := SetTunFd(-1); err == nil {
		t.Error("SetTunFd(-1) = nil, want error")
	}
	if err := SetTunFd(0); err != nil {
		t.Errorf("SetTunFd(0) = %v, want nil", err)
	}
	if err := SetTunFd(4242); err != nil {
		t.Errorf("SetTunFd(4242) = %v, want nil", err)
	}
	// Clean up so a positive fd does not leak into later tests' Start calls.
	_ = SetTunFd(0)
}

func TestSetTunFdCannotReplaceLiveDescriptor(t *testing.T) {
	if IsRunning() {
		_ = Stop()
	}
	current.mu.Lock()
	current.running = true
	current.tunFd = 17
	current.mu.Unlock()
	t.Cleanup(func() {
		current.mu.Lock()
		current.running = false
		current.tunFd = 0
		current.mu.Unlock()
	})

	if err := SetTunFd(23); err == nil {
		t.Fatal("SetTunFd while running = nil, want error")
	}
	current.mu.RLock()
	got := current.tunFd
	current.mu.RUnlock()
	if got != 17 {
		t.Fatalf("live tun fd overwritten: got %d, want 17", got)
	}
}

func TestRecoverNetworkRequiresRunningCore(t *testing.T) {
	if IsRunning() {
		_ = Stop()
	}
	if err := RecoverNetwork(); !errors.Is(err, ErrNotRunning) {
		t.Fatalf("RecoverNetwork() error = %v, want ErrNotRunning", err)
	}
}

func TestShutdownResetsStaleTunComparisonState(t *testing.T) {
	// Reproduce the upstream edge case directly: the listener has already
	// been closed, but LastTunConf still describes an enabled Android fd. A
	// subsequent fd can reuse the same integer, so shutdown must clear this
	// comparison state even when there is no live tunLister left to close.
	listener.LastTunConf = LC.Tun{Enable: true, FileDescriptor: 4242}
	shutdownMihomo()

	got := listener.GetTunConf()
	if got.Enable || got.FileDescriptor != 0 {
		t.Fatalf("stale TUN state survived shutdown: enable=%v fd=%d", got.Enable, got.FileDescriptor)
	}
}

func TestParsePrivacyDNSAndCustomRulesConfig(t *testing.T) {
	const config = `{
  "port": 0,
  "socks-port": 0,
  "mixed-port": 0,
  "external-controller": "",
  "mode": "rule",
  "allow-lan": false,
  "dns": {
    "enable": true,
    "enhanced-mode": "fake-ip",
    "fake-ip-range": "198.18.0.0/15",
    "fake-ip-filter": ["*.lan", "*.local", "localhost"],
    "nameserver-policy": {
      "+.local": "rcode://success",
      "+.in-addr.arpa": "rcode://success",
      "+.ip6.arpa": "rcode://success"
    },
    "default-nameserver": ["https://1.1.1.1/dns-query"],
    "nameserver": ["https://1.1.1.1/dns-query"],
    "proxy-server-nameserver": ["https://1.1.1.1/dns-query"],
    "direct-nameserver": ["https://1.1.1.1/dns-query"],
    "respect-rules": true
  },
  "tun": {"enable": false},
  "proxy-groups": [{"name":"PROXY","type":"select","proxies":["DIRECT"]}],
  "rules": [
    "DOMAIN-SUFFIX,example.com,DIRECT",
    "DOMAIN-KEYWORD,telemetry,REJECT",
    "MATCH,PROXY"
  ]
}`

	parsed, err := parseConfig(config)
	if err != nil {
		t.Fatalf("privacy config parse failed: %v", err)
	}
	if got := parsed.cfg.DNS.NameServer[0].ProxyName; got != "RULES" {
		t.Fatalf("dns nameserver proxy = %q, want RULES", got)
	}
	if got := len(parsed.cfg.Rules); got != 3 {
		t.Fatalf("rules count = %d, want 3", got)
	}

	if IsRunning() {
		_ = Stop()
	}
	if err := Start(config); err != nil {
		t.Fatalf("privacy config start failed: %v", err)
	}
	t.Cleanup(func() { _ = Stop() })
	status := snapshotStatus()
	if status.Listeners != (Listeners{}) {
		t.Fatalf("privacy config exposed inbound listeners: %+v", status.Listeners)
	}
	if status.Tun.Enabled {
		t.Fatal("test privacy config unexpectedly enabled TUN")
	}
}

// TestTrafficJSON_Synthetic asserts the Synthetic flag is present and false
// after this iteration — Kotlin uses it to gate its legacy fake generator.
func TestTrafficJSON_Synthetic(t *testing.T) {
	if IsRunning() {
		_ = Stop()
	}
	if err := Start(minimalYAML); err != nil {
		t.Fatalf("Start = %v", err)
	}
	defer func() { _ = Stop() }()

	var tr map[string]any
	if err := json.Unmarshal([]byte(GetTrafficJSON()), &tr); err != nil {
		t.Fatalf("Traffic JSON: %v", err)
	}
	synth, ok := tr["synthetic"].(bool)
	if !ok {
		t.Fatal("Traffic.synthetic missing or not bool")
	}
	if synth {
		t.Error("Traffic.synthetic = true, want false (real stats now)")
	}
}
