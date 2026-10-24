// Package binding is the gomobile boundary of nozelt-core. Every exported
// symbol in this file becomes part of the .aar surface consumed by Kotlin.
//
// gomobile imposes hard restrictions on supported types: only string, []byte,
// numeric primitives, error, interfaces with restricted methods, and types
// that satisfy those constraints. We therefore expose complex data as JSON
// strings rather than as structs or maps, and route logging through a
// narrow Logger interface.
//
// Treat this file like a stable ABI: changes here are breaking changes for
// every Kotlin caller. Add new functions instead of modifying existing
// signatures whenever possible.
package binding

import (
	"fmt"
	"sync"

	"github.com/nozelt/nozelt-core/core"
	"github.com/nozelt/nozelt-core/logger"
)

// Logger is the host-supplied callback interface. The signature uses only
// strings so the gomobile-generated Java/Kotlin glue stays trivially small.
type Logger interface {
	Log(level string, message string)
}

// SocketProtector is implemented by Android's VpnService. Protect is called
// synchronously for each mihomo outbound socket before connect/bind so that
// the transport cannot re-enter the TUN it is responsible for servicing.
type SocketProtector interface {
	Protect(fd int64) bool
}

// DelayListener receives one completed health-check result at a time. A
// non-positive delay represents an unavailable node.
type DelayListener interface {
	OnResult(name string, delay int64)
}

var (
	protectorMu        sync.Mutex
	installedProtector SocketProtector
)

// SetSocketProtector installs Android's VpnService.protect bridge. The
// binding retains the interface for the complete lifetime of Go callbacks.
// Pass nil after Stop has drained the engine.
func SetSocketProtector(protector SocketProtector) {
	protectorMu.Lock()
	defer protectorMu.Unlock()

	installedProtector = protector
	if protector == nil {
		core.SetSocketProtector(nil)
		return
	}
	core.SetSocketProtector(func(fd int) bool {
		return protector.Protect(int64(fd))
	})
}

// Start brings the proxy engine up with the supplied YAML configuration.
// Returns a non-nil error if the config is invalid or the engine is already
// running. Safe to call from any thread.
func Start(configYAML string) error {
	return core.Start(configYAML)
}

// Stop tears down the engine. Returns an error if the engine is not running.
func Stop() error {
	return core.Stop()
}

// StopForRestart drains the live engine while retaining only its in-memory
// FakeDNS associations for the immediately following Start. Android uses it
// for fail-closed TUN/profile replacement; final disconnects must call Stop.
func StopForRestart() error {
	return core.StopForRestart()
}

// SetTunFd hands the Android TUN file descriptor (from
// VpnService.establish() -> ParcelFileDescriptor.detachFd()) to the engine.
// Call it after establish() and before Start whenever the config enables
// TUN. Pass 0 to clear. A negative fd is rejected.
//
// Ownership: after Start applies a TUN-enabled config, mihomo's sing-tun
// listener owns this fd and closes it on Stop. The Kotlin caller must have
// detached it from its ParcelFileDescriptor so Android does not double-close.
//
// gomobile note: Go int binds to Java/Kotlin `long`, so the generated
// signature is setTunFd(long). Callers pass fd.toLong().
func SetTunFd(fd int) error {
	return core.SetTunFd(fd)
}

// SetNativeTun enables mihomo-owned TUN creation for desktop hosts. Android
// must never call this and continues to pass a VpnService descriptor.
func SetNativeTun(enabled bool) error {
	return core.SetNativeTun(enabled)
}

// ReloadConfig swaps the live config for the supplied YAML without dropping
// connections where mihomo allows it. Returns an error if the engine is not
// running or the new config is invalid.
func ReloadConfig(configYAML string) error {
	return core.ReloadConfig(configYAML)
}

// RecoverNetwork rebuilds network-bound transports while keeping the Android
// TUN listener and its file descriptor alive.
func RecoverNetwork() error {
	return core.RecoverNetwork()
}

// SetDataDir sets mihomo's home directory (geodata location). Call it before
// Start; it is refused while a session runs.
func SetDataDir(directory string) error {
	return core.SetDataDir(directory)
}

// ProbeLiveConnection checks that the running session's selected proxy still
// answers through its existing transports. Returns an error when it does not.
func ProbeLiveConnection(timeoutMs int) error {
	return core.ProbeLiveConnection(timeoutMs)
}

// SelectProxy changes a live selector for new connections without recreating
// the TUN. Nozelt uses the fixed group name "PROXY".
func SelectProxy(groupName, proxyName string) error {
	return core.SelectProxy(groupName, proxyName)
}

// GetStatus returns a JSON document describing engine state: running flag,
// uptime, embedded mihomo version, nozelt-core version. See core.Status for
// the schema.
func GetStatus() string {
	return core.GetStatusJSON()
}

// GetTraffic returns a JSON document with cumulative byte counters and the
// current up/down speed. Zeroed when the engine is not running.
func GetTraffic() string {
	return core.GetTrafficJSON()
}

// GetConnections returns a bounded JSON array of live tracker snapshots.
// The UI keeps this telemetry in memory only.
func GetConnections() string {
	return core.GetConnectionsJSON()
}

func CloseConnection(id string) bool {
	return core.CloseConnection(id)
}

func CloseAllConnections() int {
	return core.CloseAllConnections()
}

// ParseProxyLink parses a single proxy share link (vless://, vmess://, ss://,
// trojan://, hysteria2://, tuic://, anytls://, ...) into a mihomo proxy map,
// delegating to mihomo's convert package. Returns a JSON envelope:
// {"ok":true,"proxy":{...}} or {"ok":false,"error":"..."}. Never panics.
//
// Network I/O is the host's responsibility — pass the link text only.
func ParseProxyLink(link string) string {
	return core.ParseProxyLink(link)
}

// ParseSubscription parses already-downloaded subscription content into mihomo
// proxy maps. Accepts a Clash/mihomo YAML document, a base64-encoded link
// list, or a plain-text link list. Returns a JSON envelope:
// {"ok":true,"proxies":[...],"count":N} or {"ok":false,"error":"..."}.
//
// The host downloads the subscription URL (with its own User-Agent, timeout,
// proxy handling) and passes the raw body here — Go only parses.
func ParseSubscription(content string) string {
	return core.ParseSubscription(content)
}

// TestProxyDelays runs mihomo's real URL test for the named proxies. The
// config is parsed but not applied, and the network phase is accepted only
// while an active VPN owns Android's protected socket context. It cannot
// disturb the active TUN. Complex arguments/results stay JSON at the gomobile
// boundary.
func TestProxyDelays(configYAML, namesJSON, testURL string, timeoutMs int) string {
	return core.TestProxyDelays(configYAML, namesJSON, testURL, timeoutMs)
}

// TestProxyDelaysOffline runs the same real proxy URL test while the VPN is
// explicitly stopped. Proxy endpoint lookups use the config's encrypted DNS
// resolver, and a concurrent VPN Start cancels/drains the direct probes first.
func TestProxyDelaysOffline(configYAML, namesJSON, testURL string, timeoutMs int) string {
	return core.TestProxyDelaysOffline(configYAML, namesJSON, testURL, timeoutMs)
}

// TestProxyDelaysStream reports each result immediately instead of making the
// Flutter UI wait for the slowest timeout in the batch.
func TestProxyDelaysStream(
	configYAML, namesJSON, testURL string,
	timeoutMs int,
	listener DelayListener,
) string {
	return core.TestProxyDelaysStream(
		configYAML,
		namesJSON,
		testURL,
		timeoutMs,
		func(name string, delay int) {
			if listener != nil {
				listener.OnResult(name, int64(delay))
			}
		},
	)
}

// TestProxyDelaysOfflineStream is the stopped-VPN streaming equivalent.
func TestProxyDelaysOfflineStream(
	configYAML, namesJSON, testURL string,
	timeoutMs int,
	listener DelayListener,
) string {
	return core.TestProxyDelaysOfflineStream(
		configYAML,
		namesJSON,
		testURL,
		timeoutMs,
		func(name string, delay int) {
			if listener != nil {
				listener.OnResult(name, int64(delay))
			}
		},
	)
}

// CancelDelayTests aborts UI latency probes while leaving the active VPN and
// its protected transports intact. Android calls this when Flutter moves to
// the background so a large all-node test cannot drain battery indefinitely.
func CancelDelayTests() {
	core.CancelDelayTests()
}

// GetVersion returns every bundled engine version. Cheap, side-effect free.
func GetVersion() string {
	return fmt.Sprintf(
		`{"nozeltCore":"%s","mihomo":"%s","xray":"%s","singBox":"%s"}`,
		core.NozeltCoreVersion,
		core.MihomoVersion(),
		core.XrayCoreVersion,
		core.SingBoxCoreVersion,
	)
}

// SetLogger installs a host-supplied logger. Pass nil to detach. The logger
// receives every internal log line; the host decides whether to forward to
// logcat, file, or both.
func SetLogger(l Logger) {
	if l == nil {
		logger.Set(nil)
		return
	}
	logger.Set(loggerAdapter{delegate: l})
}

// loggerAdapter bridges the binding.Logger interface (the one Kotlin sees)
// to the logger.Logger interface (the one Go internals use). The two are
// shape-compatible, but keeping them separate lets us evolve internals
// without breaking the gomobile ABI.
type loggerAdapter struct {
	delegate Logger
}

func (a loggerAdapter) Log(level, message string) {
	a.delegate.Log(level, message)
}
