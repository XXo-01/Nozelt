// Package core wraps the mihomo proxy engine and exposes a thread-safe
// lifecycle (Start / Stop / Reload) to the rest of nozelt-core. It is the
// only package permitted to touch mihomo's internals; everything else goes
// through binding -> core.
package core

import (
	"errors"
	"fmt"
	"os"
	"sync"
	"time"

	"github.com/metacubex/mihomo/component/resolver"
	mconfig "github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	executor "github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/listener"
	LC "github.com/metacubex/mihomo/listener/config"
	mtunnel "github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"

	"github.com/nozelt/nozelt-core/logger"
)

// NozeltCoreVersion is the semantic version of the nozelt-core wrapper. It
// is incremented manually on tagged releases of this module. The mihomo
// version is reported separately by Version().
const NozeltCoreVersion = "0.5.0-dev"

// Native Android companion cores are pinned by native-cores/build_android.ps1.
// Keep the values here as the single UI/diagnostics source of truth.
const XrayCoreVersion = "26.9.9"
const SingBoxCoreVersion = "1.14.1"

// ErrAlreadyRunning is returned by Start when the core is already active.
var ErrAlreadyRunning = errors.New("nozelt core: already running")

// ErrNotRunning is returned by Stop/Reload when the core is idle.
var ErrNotRunning = errors.New("nozelt core: not running")

// shutdownSlowWarning controls diagnostics only. Stop deliberately waits for
// mihomo cleanup to finish: abandoning a shutdown goroutine would let a late
// cleanup close listeners belonging to a newly-started session.
const shutdownSlowWarning = 10 * time.Second

// state holds the runtime state of the embedded mihomo instance. It is a
// package-level singleton because mihomo itself is a process-wide singleton
// — the hub and tunnel manager use global state internally, so wrapping
// multiple instances per process would not work.
type state struct {
	mu             sync.RWMutex
	running        bool
	startedAt      time.Time
	configRaw      string
	cfg            *mconfig.Config   // last successfully applied config, nil when stopped
	proxySignature [32]byte          // credential-safe digest; never logged
	selections     map[string]string // live selector state, values never logged
	watchdogCancel chan struct{}
	// preserveFakeIP is set only across a technical stop/start replacement.
	// Android applications may briefly reuse a synthetic DNS answer while the
	// TUN is being rebuilt; retaining the in-memory mapper prevents that IP
	// from becoming unknown. A user-visible/final Stop always flushes it.
	preserveFakeIP           bool
	preservedFakeIPSignature string

	// tunFd is the Android TUN file descriptor handed to us by the Kotlin
	// VpnService via SetTunFd, before Start. Zero means "no TUN fd" — Start
	// will refuse a config that enables TUN without one.
	//
	// Ownership contract (single owner — the Go side):
	//   - Kotlin calls ParcelFileDescriptor.detachFd() and hands us the raw
	//     fd via SetTunFd. From that moment Android must NOT close it.
	//   - Once mihomo's sing-tun listener adopts the fd (Start succeeds), it
	//     is the effective owner and closes the fd on teardown
	//     (shutdownMihomo -> executor.Shutdown -> closeTunListener). We keep
	//     tunFd as a reference (for status and TUN-preserving reloads) and
	//     clear it in Stop after sing-tun has closed it.
	//   - If Start/apply fails before sing-tun adopts the fd, Go closes the
	//     raw fd itself (closeTunFdRawLocked). Kotlin never closes it.
	// This guarantees exactly one close and no leak on every path.
	tunFd int
	// nativeTun lets desktop hosts ask sing-tun to create and own the platform
	// interface itself. Android never enables this flag: its VpnService must
	// remain the sole owner of routes and passes a detached descriptor instead.
	nativeTun bool
}

var current = &state{}

// SetTunFd stores the Android TUN file descriptor that a subsequent Start
// (or ReloadConfig) will hand to mihomo's sing-tun listener. It must be
// called after VpnService.establish() and before Start whenever the config
// enables TUN.
//
// Pass fd == 0 to clear a previously stored descriptor. A negative fd is
// rejected. The descriptor is not touched here — it is only recorded; the
// actual adoption (and eventual close) happens inside mihomo when Start
// applies a TUN-enabled config. See the state.tunFd doc for the ownership
// contract.
func SetTunFd(fd int) error {
	if fd < 0 {
		return fmt.Errorf("nozelt core: invalid tun fd %d", fd)
	}
	current.mu.Lock()
	defer current.mu.Unlock()
	if current.running {
		// Do not overwrite the descriptor reference owned by the live sing-tun
		// listener. The caller still owns fd when this method returns an error
		// and is responsible for closing that new, unaccepted duplicate.
		return errors.New("nozelt core: cannot replace tun fd while running")
	}
	// A service can be destroyed after a successful SetTunFd but before Start
	// adopts the descriptor. A later service instance is allowed to replace
	// that abandoned pending fd; Go already owns it and must close it first.
	current.closeTunFdRawLocked()
	current.tunFd = fd
	logger.Info("nozelt core: tun fd accepted")
	return nil
}

// SetNativeTun selects the desktop TUN ownership model. It can only be
// changed while the core is stopped. Desktop hosts enable it immediately
// before Start; Android leaves the default false and continues to use
// SetTunFd. Keeping the choice explicit prevents a missing Android fd from
// silently falling back to privileged device creation.
func SetNativeTun(enabled bool) error {
	current.mu.Lock()
	defer current.mu.Unlock()
	if current.running {
		return errors.New("nozelt core: cannot change TUN ownership while running")
	}
	if enabled {
		current.closeTunFdRawLocked()
	}
	current.nativeTun = enabled
	return nil
}

// SetDataDir points mihomo at an app-private directory holding geoip.dat and
// geosite.dat. Android needs it: mihomo's default home (/sdcard/.config) is
// not writable, so GEOIP/GEOSITE rules would otherwise fail to load. Changing
// it while a session runs is refused; the next Start picks it up.
func SetDataDir(directory string) error {
	info, err := os.Stat(directory)
	if err != nil || !info.IsDir() {
		return errors.New("nozelt core: data directory is missing")
	}
	current.mu.Lock()
	defer current.mu.Unlock()
	if C.Path.HomeDir() == directory {
		return nil
	}
	if current.running {
		return errors.New("nozelt core: cannot change data directory while running")
	}
	C.SetHomeDir(directory)
	return nil
}

// Start parses configYAML, hands it to mihomo and brings the proxy engine
// up. Returns ErrAlreadyRunning if Start has already been called without a
// matching Stop, and an error wrapping mihomo's own diagnostics on config
// or listener failure.
func Start(configYAML string) error {
	current.mu.Lock()
	defer current.mu.Unlock()

	if current.running {
		// The fd Kotlin just handed us will not be used — release it so it
		// does not leak (Kotlin detached it and will not close it).
		current.closeTunFdRawLocked()
		return ErrAlreadyRunning
	}
	// Direct/offline latency probes are valid only while the VPN is fully
	// stopped. Cancel and drain them before installing the protected runtime,
	// including probes whose config finished parsing just before this lock.
	cancelAndWaitDelayTests()

	cfg, err := parseConfig(configYAML)
	if err != nil {
		current.closeTunFdRawLocked()
		return fmt.Errorf("nozelt core: parse config: %w", err)
	}
	if current.preserveFakeIP &&
		current.preservedFakeIPSignature != fakeIPConfigSignature(cfg.cfg) {
		// Cloning a mapping into a different synthetic prefix would keep cached
		// addresses outside the new pool. Drop it instead of creating an invalid
		// cross-range mapping during a user DNS-setting replacement.
		current.clearResolverStateLocked(false)
	}

	if err := applyConfig(cfg); err != nil {
		// executor.ApplyConfig mutates mihomo process-global state before its
		// listener failures become observable. Undo all of that partial state;
		// otherwise retries can accumulate adapters, DNS objects and listeners.
		current.cleanupFailedStartLocked(cfg.cfg)
		return fmt.Errorf("nozelt core: apply config: %w", err)
	}

	// Success. sing-tun (when TUN is enabled) now owns the fd for the whole
	// session; we keep current.tunFd as a reference for status reporting and
	// TUN-preserving reloads. Stop closes it via sing-tun.
	current.running = true
	current.startedAt = time.Now()
	current.configRaw = configYAML
	current.cfg = cfg.cfg
	current.proxySignature = cfg.proxySignature
	current.captureSelectionsLocked()
	current.startResourceWatchdogLocked()
	current.preserveFakeIP = false
	current.preservedFakeIPSignature = ""

	logger.Info("nozelt core started")
	return nil
}

// Stop tears down the mihomo instance and releases its resources. Safe to
// call repeatedly; second and subsequent calls return ErrNotRunning.
//
// Shutdown warns if it is unusually slow but does not return until cleanup is
// complete. This strict barrier is essential: a timed-out cleanup goroutine
// could otherwise finish after the next Start and close that new session's
// process-global mihomo listeners/TUN.
func Stop() error {
	current.mu.Lock()
	defer current.mu.Unlock()

	if !current.running {
		// A technical restart can fail after its old engine has stopped. The
		// retained FakeDNS mapper must still be removable by an explicit STOP.
		if current.preserveFakeIP {
			current.clearResolverStateLocked(false)
			logger.Info("nozelt core stopped; cleared retained restart DNS state")
			return nil
		}
		return ErrNotRunning
	}
	err := current.stopLocked(false)
	releaseMemory()
	return err
}

// StopForRestart tears down all live transports and listeners like Stop, but
// retains only the in-memory FakeDNS host mapper until the next Start. Android
// applications are allowed to cache a just-returned 198.18/15 address; keeping
// the mapping makes a fail-closed profile/TUN replacement transparent instead
// of producing a brief "VPN connected, sites do not open" window.
//
// This is strictly an internal lifecycle primitive. User-requested disconnect,
// revoke and final service cleanup must call Stop so credentials and mappings
// are erased.
func StopForRestart() error {
	current.mu.Lock()
	defer current.mu.Unlock()

	if !current.running {
		return ErrNotRunning
	}
	return current.stopLocked(true)
}

// stopLocked performs the common teardown. Caller holds current.mu.
func (s *state) stopLocked(preserveFakeIP bool) error {
	if preserveFakeIP {
		s.preservedFakeIPSignature = fakeIPConfigSignature(s.cfg)
	}
	s.stopResourceWatchdogLocked()
	cancelAndWaitDelayTests()
	closed := closeTrackedConnections()
	resolver.ResetConnection()
	shutdownMihomo()
	resolver.ClearCache()
	s.clearResolverStateLocked(
		preserveFakeIP && s.preservedFakeIPSignature != "",
	)
	closeProxyAdapters(s.cfg)
	// mihomo's process-global tunnel maps outlive executor.Shutdown(). Clear
	// their references so stopped sessions do not retain proxy credentials,
	// provider fetchers, routing domains, or custom listener objects in memory.
	mtunnel.UpdateProxies(map[string]C.Proxy{}, map[string]P.ProxyProvider{})
	mtunnel.UpdateRules(nil, nil, nil)
	mtunnel.UpdateListeners(map[string]C.InboundListener{})

	s.running = false
	s.startedAt = time.Time{}
	s.configRaw = ""
	s.cfg = nil
	s.proxySignature = [32]byte{}
	s.selections = nil
	// mihomo's sing-tun listener has closed the descriptor during
	// shutdownMihomo. Drop our reference so a later Start cannot reuse a
	// closed fd — Kotlin must establish() and SetTunFd again.
	s.tunFd = 0

	if preserveFakeIP && s.preserveFakeIP {
		logger.Info(fmt.Sprintf(
			"nozelt core paused for restart; closed %d tracked connections", closed))
	} else {
		logger.Info(fmt.Sprintf("nozelt core stopped; closed %d tracked connections", closed))
	}
	return nil
}

// clearResolverStateLocked releases every network-bearing resolver object.
// When preserveFakeIP is true, the host mapper alone remains: it contains the
// synthetic IP/domain association but no DNS transport. executor.updateDNS
// clones it into the next resolver on Start. Caller holds current.mu.
func (s *state) clearResolverStateLocked(preserveFakeIP bool) {
	if !preserveFakeIP {
		_ = resolver.FlushFakeIP()
		resolver.DefaultHostMapper = nil
	}
	resolver.DefaultResolver = nil
	resolver.DefaultService = nil
	resolver.ProxyServerHostResolver = nil
	resolver.DirectHostResolver = nil
	s.preserveFakeIP = preserveFakeIP && resolver.DefaultHostMapper != nil
	if !s.preserveFakeIP {
		s.preservedFakeIPSignature = ""
	}
}

func fakeIPConfigSignature(cfg *mconfig.Config) string {
	if cfg == nil || cfg.DNS == nil || !cfg.DNS.Enable ||
		cfg.DNS.EnhancedMode != C.DNSFakeIP {
		return ""
	}
	return fmt.Sprintf(
		"%s|%t|%s",
		cfg.DNS.FakeIPRange.String(),
		cfg.DNS.IPv6,
		cfg.DNS.FakeIPRange6.String(),
	)
}

// cleanupFailedStartLocked reverses a partial executor.ApplyConfig. It also
// releases the detached Android fd according to whether sing-tun adopted it.
// The candidate adapters are not recorded in current.cfg on a failed Start,
// so they must be closed explicitly here. Caller holds current.mu.
func (s *state) cleanupFailedStartLocked(candidate *mconfig.Config) {
	s.stopResourceWatchdogLocked()
	cancelAndWaitDelayTests()
	_ = closeTrackedConnections()
	resolver.ResetConnection()

	tunAdopted := s.tunFd > 0 && listener.GetTunConf().Enable
	shutdownMihomo()
	if tunAdopted {
		// shutdownMihomo closed the sing-tun-owned descriptor.
		s.tunFd = 0
	} else {
		// The failed listener never adopted Kotlin's detached descriptor.
		s.closeTunFdRawLocked()
	}

	resolver.ClearCache()
	s.clearResolverStateLocked(s.preserveFakeIP)
	closeProxyAdapters(candidate)
	mtunnel.UpdateProxies(map[string]C.Proxy{}, map[string]P.ProxyProvider{})
	mtunnel.UpdateRules(nil, nil, nil)
	mtunnel.UpdateListeners(map[string]C.InboundListener{})
}

// ReloadConfig replaces the live mihomo config without dropping established
// connections where mihomo allows it. The core must be running. On failure
// the wrapper retains the last successfully applied configuration so status
// remains truthful and the caller can retry or Stop the existing session.
func ReloadConfig(configYAML string) error {
	current.mu.Lock()
	defer current.mu.Unlock()

	if !current.running {
		return ErrNotRunning
	}
	cancelAndWaitDelayTests()

	cfg, err := parseConfig(configYAML)
	if err != nil {
		return fmt.Errorf("nozelt core: parse config: %w", err)
	}

	oldCfg := current.cfg
	if current.tunFd > 0 && oldCfg != nil && oldCfg.General != nil {
		// An Android TUN descriptor cannot be reused by a new listener: a
		// changed stack, MTU or address would close it and reopen a number
		// that may already belong to another socket. That needs a restart.
		next := cfg.cfg.General.Tun
		next.FileDescriptor = oldCfg.General.Tun.FileDescriptor
		if !next.Equal(oldCfg.General.Tun) {
			closeProxyAdapters(cfg.cfg)
			return errors.New("nozelt core: tun change requires restart")
		}
	}
	sameProxyDefinitions := oldCfg != nil && current.proxySignature == cfg.proxySignature
	if sameProxyDefinitions {
		// Parsing constructs a complete throwaway set of outbound adapters.
		// Reuse the live instances when only rules/DNS changed, and release the
		// unused parsed copies before applying the rest of the configuration.
		unusedProxies := cfg.cfg.Proxies
		unusedProviders := cfg.cfg.Providers
		cfg.cfg.Proxies = oldCfg.Proxies
		cfg.cfg.Providers = oldCfg.Providers
		closeProxyMap(unusedProxies)
		closeProxyProviderMap(unusedProviders)
	}

	if err := applyConfig(cfg); err != nil {
		if sameProxyDefinitions {
			// Live proxy/provider instances were borrowed from oldCfg above;
			// only the newly parsed rule providers belong to this failed
			// candidate and are safe to close here.
			closeRuleProviderMap(cfg.cfg.RuleProviders)
		} else {
			// The failed candidate owns all of its adapters. executor may have
			// published them before listener verification failed, but the live
			// caller immediately rolls the previous config back; retaining these
			// abandoned clients would leak QUIC/TLS/provider resources.
			closeProxyAdapters(cfg.cfg)
		}
		// mihomo's ApplyConfig has already mutated its internal state by the
		// time we discover a port mismatch. We keep current.running = true
		// so the caller can see the failure but still has a working Stop().
		// current.cfg is left pointing at the old config so getStatus does
		// not lie about the active mode. Reload does NOT release the fd on
		// failure — the still-running session's sing-tun still owns it.
		return fmt.Errorf("nozelt core: apply config: %w", err)
	}

	current.configRaw = configYAML
	current.cfg = cfg.cfg
	current.proxySignature = cfg.proxySignature
	current.restoreSelectionsLocked()
	current.captureSelectionsLocked()
	if !sameProxyDefinitions {
		// mihomo's tunnel.UpdateProxies swaps the map but does not close the
		// previous adapters. Explicit cleanup prevents repeated live reloads
		// from accumulating QUIC/TLS clients and file descriptors.
		closeProxyAdapters(oldCfg)
	} else if oldCfg != nil {
		// Proxy/provider instances were reused, but rule providers are rebuilt
		// independently by every parse/apply and must release their fetchers.
		closeRuleProviderMap(oldCfg.RuleProviders)
	}
	logger.Info("nozelt core config reloaded")
	return nil
}

// RecoverNetwork refreshes every network-bound mihomo resource after Android's
// underlying network changes (for example mobile -> Wi-Fi) without replacing
// the Android TUN file descriptor. Existing TCP/UDP trackers are closed so apps
// reconnect, proxy adapters are rebuilt so pooled QUIC/HY2 sessions do not keep
// using the dead path, and DNS transports are reset by ApplyConfig.
func RecoverNetwork() error {
	current.mu.Lock()
	defer current.mu.Unlock()

	if !current.running {
		return ErrNotRunning
	}
	cancelAndWaitDelayTests()

	p, err := parseConfig(current.configRaw)
	if err != nil {
		return fmt.Errorf("nozelt core: parse recovery config: %w", err)
	}

	closed := closeTrackedConnections()
	resolver.ResetConnection()

	oldCfg := current.cfg
	if err := applyConfig(p); err != nil {
		closeProxyAdapters(p.cfg)
		return fmt.Errorf("nozelt core: recover network: %w", err)
	}

	current.cfg = p.cfg
	current.proxySignature = p.proxySignature
	current.restoreSelectionsLocked()
	current.captureSelectionsLocked()
	closeProxyAdapters(oldCfg)
	logger.Info(fmt.Sprintf("nozelt core: network recovered; closed %d stale connections", closed))
	return nil
}

// IsRunning reports whether the core is currently active. Cheap, non-blocking.
func IsRunning() bool {
	current.mu.RLock()
	defer current.mu.RUnlock()
	return current.running
}

// startedAt returns the start timestamp; zero value when stopped.
func startedAt() time.Time {
	current.mu.RLock()
	defer current.mu.RUnlock()
	return current.startedAt
}

// currentConfig returns the last successfully applied mihomo config under
// the read lock. Returns nil when the engine is not running.
func currentConfig() *mconfig.Config {
	current.mu.RLock()
	defer current.mu.RUnlock()
	return current.cfg
}

// applyConfig hands a parsed config to mihomo's executor, then sanity-checks
// that every inbound the user asked for actually came up.
//
// TUN fd injection: the Kotlin side does not put the file descriptor into
// the YAML (it does not own the config text). Instead it calls SetTunFd,
// and here — while current.mu is held by the Start/ReloadConfig caller — we
// stamp the stored fd onto cfg.General.Tun.FileDescriptor just before
// ApplyConfig. mihomo's sing-tun then adopts that fd instead of opening its
// own device. A TUN-enabled config with no fd is a hard error: without it
// sing-tun would try to open /dev/net/tun via ioctl, which fails on
// non-rooted Android.
//
// Why the sanity checks: executor.ApplyConfig has signature func(...) and
// never returns an error — bind/listen failures are only visible in
// mihomo's log stream. Without these checks Start() would return nil while
// no traffic flows. We compare requested inbound ports against
// listener.GetPorts(), and (when TUN is enabled) confirm the TUN listener
// is actually up via listener.GetTunConf().
//
// Precondition: caller holds current.mu (Start / ReloadConfig do). Start owns
// cleanup of a failed initial apply; a live reload keeps the existing fd so
// its host can roll the previous configuration back.
func applyConfig(p *parsedConfig) error {
	tunEnabled := p.cfg.General.Tun.Enable
	if tunEnabled {
		if current.tunFd <= 0 && !current.nativeTun {
			// Nothing to clean up: no fd was ever handed to mihomo.
			return fmt.Errorf(
				"tun is enabled but no tun fd is set; call SetTunFd after VpnService.establish()")
		}
		if current.tunFd > 0 {
			p.cfg.General.Tun.FileDescriptor = current.tunFd
		}
	}

	executor.ApplyConfig(p.cfg, true)

	if err := verifyListeners(p.cfg); err != nil {
		return err
	}

	// TUN verification: ReCreateTun swallows its error (it only logs and flips
	// Enable=false on LastTunConf), so we read it back via GetTunConf. A live
	// listener reports Enable=true; a failed one reports Enable=false. When it
	// failed, sing-tun never adopted the fd. Start owns complete partial-state
	// cleanup; a live Reload leaves its existing descriptor untouched so the
	// host can roll the previous config back.
	if tunEnabled && !listener.GetTunConf().Enable {
		return fmt.Errorf(
			"failed to start TUN listener (stack=%s; see mihomo logs)",
			p.cfg.General.Tun.Stack.String())
	}
	return nil
}

// closeTunFdRawLocked closes and clears a stored TUN fd that mihomo's sing-tun
// has NOT adopted. os.NewFile+Close is the portable way to close a raw
// descriptor exactly once (it also compiles on the non-Unix dev host). No-op
// when the fd is already cleared. Caller holds current.mu.
func (s *state) closeTunFdRawLocked() {
	if s.tunFd <= 0 {
		return
	}
	if f := os.NewFile(uintptr(s.tunFd), "nozelt-tun"); f != nil {
		_ = f.Close()
	}
	s.tunFd = 0
}

// verifyListeners compares every inbound port requested in cfg.General to the
// ports actually open after ApplyConfig. Equality is deliberate, including
// zero: Nozelt's TUN-only config requests no localhost proxy, so a stale or
// unexpectedly opened listener is a privacy failure rather than harmless
// extra functionality.
func verifyListeners(cfg *mconfig.Config) error {
	ports := listener.GetPorts()
	checks := []struct {
		name string
		want int
		got  int
	}{
		{"mixed-port", cfg.General.MixedPort, ports.MixedPort},
		{"port", cfg.General.Port, ports.Port},
		{"socks-port", cfg.General.SocksPort, ports.SocksPort},
		{"redir-port", cfg.General.RedirPort, ports.RedirPort},
		{"tproxy-port", cfg.General.TProxyPort, ports.TProxyPort},
	}
	for _, c := range checks {
		if c.got != c.want {
			return fmt.Errorf(
				"failed to open %s: configured=%d, actual=%d (port likely in use; see mihomo logs)",
				c.name, c.want, c.got,
			)
		}
	}
	return nil
}

// shutdownMihomo stops the embedded mihomo instance.
//
// Two phases:
//  1. executor.Shutdown() — runs mihomo's own teardown. This calls
//     listener.Cleanup() -> closeTunListener(), which closes the sing-tun
//     listener and, with it, the Android TUN file descriptor we injected
//     (sing-tun owns it and closes it here — this is the single close of
//     that fd; Kotlin detached it and must not close it again).
//  2. Re-create each non-TUN listener with port=0 — executor.Shutdown
//     intentionally does not touch HTTP/SOCKS/Mixed/Redir/TProxy because
//     in mihomo's CLI usage the process exits right after. We keep
//     running, so we close them explicitly to free the ports.
//
// The slow timer is diagnostic only. This call remains a hard lifecycle
// barrier because mihomo owns process-global listeners.
func shutdownMihomo() {
	warning := time.AfterFunc(shutdownSlowWarning, func() {
		logger.Warn("nozelt core: shutdown is still running after 10s")
	})
	defer warning.Stop()

	executor.Shutdown()
	// Upstream Cleanup closes tunLister but deliberately leaves LastTunConf
	// intact. Android commonly reuses the same integer for the duplicated TUN
	// fd on the next establish. ReCreateTun would then see an equal config,
	// find tunLister == nil, return without opening anything, and GetTunConf
	// would still report the stale enabled config. Reset the comparison state
	// after the listener is closed so every later Start must adopt its new fd.
	listener.ReCreateTun(LC.Tun{}, mtunnel.Tunnel)
	listener.ReCreateHTTP(0, mtunnel.Tunnel)
	listener.ReCreateSocks(0, mtunnel.Tunnel)
	listener.ReCreateRedir(0, mtunnel.Tunnel)
	listener.ReCreateTProxy(0, mtunnel.Tunnel)
	listener.ReCreateMixed(0, mtunnel.Tunnel)
}

// closeProxyAdapters releases every outbound/provider resource created while
// parsing a config. This is especially important for QUIC-based adapters
// (HY2/TUIC) and provider health/fetch tasks, which mihomo's executor.Shutdown
// deliberately leaves alive because its CLI normally exits the process.
func closeProxyAdapters(cfg *mconfig.Config) {
	if cfg == nil {
		return
	}
	closeProxyMap(cfg.Proxies)
	closeProxyProviderMap(cfg.Providers)
	closeRuleProviderMap(cfg.RuleProviders)
}

func closeProxyMap(proxies map[string]C.Proxy) {
	for _, proxy := range proxies {
		_ = proxy.Close()
	}
}

type resourceCloser interface {
	Close() error
}

func closeProxyProviderMap(providers map[string]P.ProxyProvider) {
	for _, provider := range providers {
		if closer, ok := provider.(resourceCloser); ok {
			_ = closer.Close()
		}
	}
}

func closeRuleProviderMap(providers map[string]P.RuleProvider) {
	for _, provider := range providers {
		if closer, ok := provider.(resourceCloser); ok {
			_ = closer.Close()
		}
	}
}

func closeTrackedConnections() int {
	closed := 0
	statistic.DefaultManager.Range(func(connection statistic.Tracker) bool {
		_ = connection.Close()
		closed++
		return true
	})
	return closed
}

// startResourceWatchdogLocked adds a last-resort circuit breaker against a
// transport regression exhausting Android's per-process fd limit. Normal
// sessions stay below a few hundred descriptors; 1024 indicates a runaway
// retry/leak and is safer to recover by dropping stale sessions than to let
// the entire VPN and Flutter UI die at ~32768 descriptors.
func (s *state) startResourceWatchdogLocked() {
	s.stopResourceWatchdogLocked()
	cancel := make(chan struct{})
	s.watchdogCancel = cancel
	go func() {
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				fds := countOpenFileDescriptors()
				if fds >= 1024 {
					logger.Error(fmt.Sprintf(
						"nozelt core: resource guard triggered at %d open fds; recovering network transports",
						fds,
					))
					if err := RecoverNetwork(); err != nil && !errors.Is(err, ErrNotRunning) {
						// Nested mihomo errors can include an endpoint or other
						// profile-derived value. The host redacts too, but core-owned
						// diagnostics remain secret-free at the source.
						logger.Error("nozelt core: resource guard recovery failed")
					}
				}
			case <-cancel:
				return
			}
		}
	}()
}

func (s *state) stopResourceWatchdogLocked() {
	if s.watchdogCancel == nil {
		return
	}
	close(s.watchdogCancel)
	s.watchdogCancel = nil
}
