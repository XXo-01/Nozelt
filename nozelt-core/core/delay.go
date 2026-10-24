package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/component/ca"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	mdns "github.com/metacubex/mihomo/dns"
	mtunnel "github.com/metacubex/mihomo/tunnel"

	"github.com/nozelt/nozelt-core/logger"
)

const defaultDelayTestURL = "https://www.gstatic.com/generate_204"

var fallbackDelayTestURLs = []string{
	"http://cp.cloudflare.com/generate_204",
	"http://connectivitycheck.gstatic.com/generate_204",
	"http://captive.apple.com/hotspot-detect.html",
}

const (
	maxDelayNames          = maxSubscriptionProxies
	maxDelayNamesJSONBytes = 1024 * 1024
	maxDelayTestURLBytes   = 2048
	// Typical subscriptions contain several dozen nodes. Keeping only eight
	// probes active made unreachable endpoints accumulate in 15-second waves,
	// so one profile-wide check could take close to a minute. Thirty-two still
	// bounds sockets/memory while allowing ordinary mobile profiles to finish
	// within one per-node timeout window.
	maxDelayWorkers = 32
)

var activeDelayTests = struct {
	sync.Mutex
	nextID     uint64
	generation uint64
	cancels    map[uint64]context.CancelFunc
	wait       sync.WaitGroup
}{cancels: make(map[uint64]context.CancelFunc)}

// Mihomo runtime state is process-global. Only one test may temporarily
// initialize its DNS/proxy state while Mihomo itself is stopped (either
// completely offline or while Xray/sing-box owns the Android VPN).
var temporaryDelayRuntimeMu sync.Mutex

type delayNetworkMode uint8

const (
	delayThroughActiveVPN delayNetworkMode = iota
	delayDirectWhileStopped
)

type delayResult struct {
	Delay int    `json:"delay,omitempty"`
	Error string `json:"error,omitempty"`
}

type delayTarget struct {
	Name string `json:"name"`
	URL  string `json:"url,omitempty"`
}

type delayEnvelope struct {
	OK      bool                   `json:"ok"`
	Results map[string]delayResult `json:"results,omitempty"`
	Error   string                 `json:"error,omitempty"`
}

// TestProxyDelays parses the supplied config without applying it, then runs
// mihomo's real Proxy.URLTest for every requested proxy. The network phase is
// permitted only while the VPN is running, so hostname resolution and probe
// sockets inherit Android's protected transport instead of leaking through
// an unprotected system path. It does not create a temporary TUN or listener.
//
// namesJSON is a JSON string array. The result is always a JSON envelope so the
// gomobile boundary never has to transport maps or partial errors.
func TestProxyDelays(configYAML, namesJSON, testURL string, timeoutMs int) string {
	return testProxyDelays(configYAML, namesJSON, testURL, timeoutMs, delayThroughActiveVPN, nil)
}

// TestProxyDelaysOffline performs an explicit direct proxy test while the VPN
// core and Android socket protector are both stopped. Unlike an implicit
// fallback, this entry point cannot run during fail-closed recovery. Proxy
// endpoint names use only encrypted resolvers from the supplied config.
func TestProxyDelaysOffline(configYAML, namesJSON, testURL string, timeoutMs int) string {
	return testProxyDelays(configYAML, namesJSON, testURL, timeoutMs, delayDirectWhileStopped, nil)
}

// TestProxyDelaysStream is TestProxyDelays with a completion callback. The
// callback fires from worker goroutines as each result becomes available.
func TestProxyDelaysStream(
	configYAML, namesJSON, testURL string,
	timeoutMs int,
	onResult func(name string, delay int),
) string {
	return testProxyDelays(
		configYAML,
		namesJSON,
		testURL,
		timeoutMs,
		delayThroughActiveVPN,
		onResult,
	)
}

// TestProxyDelaysOfflineStream is the stopped-VPN equivalent.
func TestProxyDelaysOfflineStream(
	configYAML, namesJSON, testURL string,
	timeoutMs int,
	onResult func(name string, delay int),
) string {
	return testProxyDelays(
		configYAML,
		namesJSON,
		testURL,
		timeoutMs,
		delayDirectWhileStopped,
		onResult,
	)
}

func testProxyDelays(
	configYAML, namesJSON, testURL string,
	timeoutMs int,
	mode delayNetworkMode,
	onResult func(name string, delay int),
) string {
	testGeneration := delayTestGeneration()
	if len(namesJSON) > maxDelayNamesJSONBytes {
		return marshalDelayEnvelope(delayEnvelope{OK: false, Error: "proxy names exceed the safe size limit"})
	}
	parsed, err := parseConfig(configYAML)
	if err != nil {
		return marshalDelayEnvelope(delayEnvelope{OK: false, Error: "invalid proxy configuration"})
	}
	var finishDelayTest func()
	var finishTemporaryRuntime func()
	defer func() {
		// A temporary runtime must release its process-global references
		// before its adapters are closed. Both paths finish all QUIC/TLS cleanup
		// before unregistering, so Android cannot switch socket mode midway.
		if finishTemporaryRuntime != nil {
			finishTemporaryRuntime()
		}
		closeProxyAdapters(parsed.cfg)
		if finishDelayTest != nil {
			finishDelayTest()
		}
	}()

	targets, err := parseDelayTargets(namesJSON, testURL)
	if err != nil {
		return marshalDelayEnvelope(delayEnvelope{OK: false, Error: err.Error()})
	}
	if len(targets) == 0 {
		return marshalDelayEnvelope(delayEnvelope{OK: true, Results: map[string]delayResult{}})
	}

	if timeoutMs < 500 {
		timeoutMs = 500
	}
	if timeoutMs > 30000 {
		timeoutMs = 30000
	}
	testContext, finish, accepted, needsTemporaryRuntime := beginDelayTest(testGeneration, mode)
	if !accepted {
		errorMessage := "delay tests require an active VPN"
		if mode == delayDirectWhileStopped {
			errorMessage = "offline delay tests require a fully stopped VPN"
		}
		return marshalDelayEnvelope(delayEnvelope{OK: false, Error: errorMessage})
	}
	finishDelayTest = finish
	testProxies := parsed.cfg.Proxies
	if needsTemporaryRuntime {
		finishTemporaryRuntime, err = startTemporaryDelayRuntime(parsed)
		if err != nil {
			return marshalDelayEnvelope(delayEnvelope{OK: false, Error: err.Error()})
		}
	}

	results := make(map[string]delayResult, len(targets))
	var resultMu sync.Mutex
	publish := func(name string, result delayResult) {
		resultMu.Lock()
		results[name] = result
		resultMu.Unlock()
		if onResult != nil {
			onResult(name, result.Delay)
		}
	}
	var wg sync.WaitGroup
	// A fixed worker pool bounds both live handshakes and goroutine memory for
	// large but valid subscriptions. The previous one-goroutine-per-node shape
	// still kept only eight sockets open, but thousands of parked goroutines
	// could make an all-node refresh unnecessarily expensive on Android.
	workerCount := min(maxDelayWorkers, len(targets))
	jobs := make(chan delayTarget)
	for range workerCount {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for target := range jobs {
				proxy, exists := testProxies[target.Name]
				if !exists {
					publish(target.Name, delayResult{Error: "proxy not found"})
					continue
				}
				if needsTemporaryRuntime {
					// Resolve the proxy endpoint explicitly through the encrypted
					// runtime resolver. Besides making the privacy property auditable,
					// this warms DoH/DoT before a latency-sensitive Gecko handshake.
					host, _, splitErr := net.SplitHostPort(proxy.Addr())
					if splitErr != nil {
						publish(target.Name, delayResult{Error: "invalid proxy endpoint"})
						continue
					}
					endpointResolver := resolver.ProxyServerHostResolver
					if endpointResolver == nil {
						publish(target.Name, delayResult{Error: "encrypted DNS unavailable"})
						continue
					}
					dnsContext, dnsCancel := context.WithTimeout(testContext, 2*time.Second)
					_, dnsErr := endpointResolver.LookupIP(dnsContext, host)
					dnsCancel()
					if dnsErr != nil {
						logger.Warn("nozelt core: delay encrypted DNS preflight failed")
						publish(target.Name, delayResult{Error: "encrypted DNS failed"})
						continue
					}
					logger.Info("nozelt core: delay encrypted DNS preflight succeeded")
				}

				attemptTimeout := time.Duration(timeoutMs) * time.Millisecond
				if attemptTimeout > 2500*time.Millisecond {
					attemptTimeout = 2500 * time.Millisecond
				}
				ctx, cancel := context.WithTimeout(testContext, attemptTimeout*4)
				delay, testErr := measureProxyDelay(ctx, proxy, target.URL, attemptTimeout)
				ctxErr := ctx.Err()
				cancel()

				result := delayResult{Delay: delay}
				if testErr != nil || delay == 0 {
					if ctxErr != nil {
						result.Error = "timeout"
					} else if testErr != nil {
						// Transport/TLS errors often contain the endpoint. The UI only
						// needs a stable failure category, never the private address.
						result.Error = "proxy test failed"
						logger.Warn("nozelt core: delay test failed (" + classifyDelayError(testErr) + ")")
					} else {
						result.Error = "delay test failed"
					}
					result.Delay = 0
				}

				publish(target.Name, result)
			}
		}()
	}
	feedCancelled := false
	for _, target := range targets {
		if testContext.Err() != nil {
			break
		}
		select {
		case jobs <- target:
		case <-testContext.Done():
			feedCancelled = true
		}
		if feedCancelled {
			break
		}
	}
	close(jobs)
	wg.Wait()
	if testContext.Err() != nil {
		for _, target := range targets {
			if _, exists := results[target.Name]; !exists {
				results[target.Name] = delayResult{Error: "cancelled"}
			}
		}
	}

	return marshalDelayEnvelope(delayEnvelope{OK: true, Results: results})
}

// measureProxyDelay is Nozelt's core-independent latency definition mirrored
// by Android's Xray/sing-box SOCKS prober. measureProxyDelayOnce already makes
// a cold and a warm HTTP exchange through one connection. A successful pair
// is sufficient; repeating it doubled healthy-node latency. Failed candidates
// still rotate across harmless captive-portal endpoints and retry the
// subscription endpoint, so a lost packet or a mobile white-list does not
// immediately mark a working proxy unavailable.
func measureProxyDelay(
	ctx context.Context,
	proxy C.Proxy,
	rawURL string,
	attemptTimeout time.Duration,
) (int, error) {
	urls := delayProbeURLs(rawURL)
	var lastErr error
	for _, candidate := range urls {
		if ctx.Err() != nil {
			return 0, ctx.Err()
		}
		attemptCtx, cancel := context.WithTimeout(ctx, attemptTimeout)
		delay, err := measureProxyDelayOnce(attemptCtx, proxy, candidate)
		cancel()
		if err != nil {
			lastErr = err
			continue
		}
		return delay, nil
	}
	if lastErr == nil {
		lastErr = errors.New("all delay probes failed")
	}
	return 0, lastErr
}

func delayProbeURLs(rawURL string) []string {
	primary := strings.TrimSpace(rawURL)
	if primary == "" {
		primary = defaultDelayTestURL
	}
	unique := make([]string, 0, 4)
	appendUnique := func(candidate string) {
		for _, existing := range unique {
			if existing == candidate {
				return
			}
		}
		unique = append(unique, candidate)
	}
	appendUnique(primary)
	for _, candidate := range fallbackDelayTestURLs {
		appendUnique(candidate)
	}
	// Re-test the subscription endpoint after the first fallback. A transient
	// loss on the first request should not force the displayed result to be
	// based on a different continent's captive-portal service.
	if len(unique) > 1 {
		result := []string{unique[0], unique[1], unique[0]}
		if len(unique) > 2 {
			result = append(result, unique[2])
		}
		return result
	}
	return []string{primary, primary}
}

func representativeDelay(delays []int) int {
	values := append([]int(nil), delays...)
	sort.Ints(values)
	// Use the lower median. It filters positive congestion spikes without
	// inventing a value below an actual completed request.
	return values[(len(values)-1)/2]
}

func measureProxyDelayOnce(ctx context.Context, proxy C.Proxy, rawURL string) (int, error) {
	metadata, err := delayURLMetadata(rawURL)
	if err != nil {
		return 0, err
	}

	coldStarted := time.Now()
	instance, err := proxy.DialContext(ctx, &metadata)
	if err != nil {
		return 0, err
	}
	defer instance.Close()

	request, err := http.NewRequestWithContext(ctx, http.MethodHead, rawURL, nil)
	if err != nil {
		return 0, err
	}
	tlsConfig, err := ca.GetTLSConfig(ca.Option{})
	if err != nil {
		return 0, err
	}
	transport := &http.Transport{
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			return instance, nil
		},
		MaxIdleConns:          1,
		IdleConnTimeout:       30 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ExpectContinueTimeout: time.Second,
		TLSClientConfig:       tlsConfig,
	}
	client := http.Client{
		Transport: transport,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	defer client.CloseIdleConnections()

	response, err := client.Do(request)
	if err != nil {
		return 0, err
	}
	_ = response.Body.Close()
	coldDelay := elapsedMilliseconds(coldStarted)

	warmStarted := time.Now()
	warmResponse, warmErr := client.Do(request)
	if warmErr != nil {
		return coldDelay, nil
	}
	_ = warmResponse.Body.Close()
	return elapsedMilliseconds(warmStarted), nil
}

func delayURLMetadata(rawURL string) (metadata C.Metadata, err error) {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return metadata, err
	}
	port := parsed.Port()
	if port == "" {
		switch parsed.Scheme {
		case "http":
			port = "80"
		case "https":
			port = "443"
		default:
			return metadata, fmt.Errorf("unsupported delay URL scheme")
		}
	}
	if parsed.Hostname() == "" {
		return metadata, fmt.Errorf("delay URL host is missing")
	}
	if err = metadata.SetRemoteAddress(net.JoinHostPort(parsed.Hostname(), port)); err != nil {
		return metadata, err
	}
	return metadata, nil
}

func elapsedMilliseconds(started time.Time) int {
	elapsed := time.Since(started).Milliseconds()
	if elapsed < 1 {
		return 1
	}
	if elapsed > int64(^uint16(0)) {
		return int(^uint16(0))
	}
	return int(elapsed)
}

// parseDelayTargets accepts the legacy string array and the richer per-proxy
// target array used by Xray/Happ automatic groups. A subscription-specific
// connectivity URL is kept per concrete outbound, so a mobile white-list
// bypass group is not incorrectly tested against a generic destination that
// its provider deliberately does not expose.
func parseDelayTargets(namesJSON, fallbackURL string) ([]delayTarget, error) {
	var names []string
	if err := json.Unmarshal([]byte(namesJSON), &names); err == nil {
		targets := make([]delayTarget, 0, len(names))
		for _, name := range names {
			targets = append(targets, delayTarget{Name: name})
		}
		return normalizeDelayTargets(targets, fallbackURL)
	}

	var targets []delayTarget
	if err := json.Unmarshal([]byte(namesJSON), &targets); err != nil {
		return nil, fmt.Errorf("invalid proxy names")
	}
	return normalizeDelayTargets(targets, fallbackURL)
}

func normalizeDelayTargets(targets []delayTarget, fallbackURL string) ([]delayTarget, error) {
	if len(targets) > maxDelayNames {
		return nil, fmt.Errorf("too many proxy names")
	}
	if strings.TrimSpace(fallbackURL) == "" {
		fallbackURL = defaultDelayTestURL
	}
	seen := make(map[string]struct{}, len(targets))
	for index := range targets {
		target := &targets[index]
		if target.Name == "" {
			return nil, fmt.Errorf("invalid proxy names")
		}
		if _, exists := seen[target.Name]; exists {
			return nil, fmt.Errorf("duplicate proxy names")
		}
		seen[target.Name] = struct{}{}
		if strings.TrimSpace(target.URL) == "" {
			target.URL = fallbackURL
		}
		parsedURL, err := url.Parse(target.URL)
		if err != nil || len(target.URL) > maxDelayTestURLBytes ||
			(parsedURL.Scheme != "http" && parsedURL.Scheme != "https") ||
			parsedURL.Host == "" || parsedURL.User != nil {
			return nil, fmt.Errorf("delay test URL must be a valid HTTP(S) URL")
		}
	}
	return targets, nil
}

func classifyDelayError(err error) string {
	if err == nil {
		return "unknown"
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "timeout"
	}
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return "dns"
	}
	message := strings.ToLower(err.Error())
	switch {
	case strings.Contains(message, "timeout"), strings.Contains(message, "deadline"):
		return "timeout"
	case strings.Contains(message, "certificate"), strings.Contains(message, "tls"):
		return "tls"
	case strings.Contains(message, "connection refused"):
		return "refused"
	case strings.Contains(message, "network is unreachable"), strings.Contains(message, "no route"):
		return "route"
	case strings.Contains(message, "gecko"):
		return "gecko"
	default:
		return "transport"
	}
}

// beginDelayTest registers only the network phase of a delay test. Parsing is
// intentionally done first: it creates no sockets and therefore must not make
// Stop wait on a large JSON document. Registration itself is synchronized with
// current.running so Stop either sees and cancels this test, or the test sees a
// stopped core and refuses to dial without Android socket protection.
func beginDelayTest(
	expectedGeneration uint64,
	mode delayNetworkMode,
) (context.Context, func(), bool, bool) {
	current.mu.RLock()
	defer current.mu.RUnlock()

	protectionEnabled, _, _ := socketProtectionStatus()
	needsTemporaryRuntime := false
	switch mode {
	case delayThroughActiveVPN:
		if !current.running {
			if !protectionEnabled {
				return nil, func() {}, false, false
			}
			// Xray and sing-box run outside the Go binding, but Android installs
			// the same VpnService.protect callback for the entire requested VPN
			// lifecycle. A listener-free temporary Mihomo runtime can therefore
			// probe those profiles without looping back into their TUN.
			needsTemporaryRuntime = true
		}
	case delayDirectWhileStopped:
		if current.running || protectionEnabled {
			// A protector without a running core is the Android fail-closed
			// recovery window, not permission to create a direct probe.
			return nil, func() {}, false, false
		}
		needsTemporaryRuntime = true
	default:
		return nil, func() {}, false, false
	}

	ctx, finish, accepted := registerDelayTest(expectedGeneration)
	return ctx, finish, accepted, needsTemporaryRuntime
}

// registerDelayTest makes a probe cancellable by Stop/Reload/RecoverNetwork.
// The caller must hold current.mu (read or write) so registration cannot race
// a lifecycle operation that is about to cancel and wait for every test.
func registerDelayTest(expectedGeneration uint64) (context.Context, func(), bool) {
	ctx, cancel := context.WithCancel(context.Background())
	activeDelayTests.Lock()
	if activeDelayTests.generation != expectedGeneration {
		activeDelayTests.Unlock()
		cancel()
		return nil, func() {}, false
	}
	id := activeDelayTests.nextID
	activeDelayTests.nextID++
	activeDelayTests.cancels[id] = cancel
	activeDelayTests.wait.Add(1)
	activeDelayTests.Unlock()

	var once sync.Once
	return ctx, func() {
		once.Do(func() {
			activeDelayTests.Lock()
			delete(activeDelayTests.cancels, id)
			activeDelayTests.Unlock()
			cancel()
			activeDelayTests.wait.Done()
		})
	}, true
}

// liveProbeGroup is the selector every Nozelt profile routes proxied traffic
// through (see config_builder.dart groupSelect).
const liveProbeGroup = "PROXY"

// ProbeLiveConnection sends one small HTTP request through the running
// session's own PROXY group, reusing its pooled QUIC/TLS transports. Android
// calls it after the screen wakes: a success means the existing session still
// works and does not need to be torn down. Any failure (including a missing
// group) tells the caller to rebuild the transports.
func ProbeLiveConnection(timeoutMs int) error {
	testGeneration := delayTestGeneration()
	if timeoutMs < 500 {
		timeoutMs = 500
	}
	if timeoutMs > 15000 {
		timeoutMs = 15000
	}

	current.mu.RLock()
	if !current.running || current.cfg == nil {
		current.mu.RUnlock()
		return ErrNotRunning
	}
	proxy, exists := current.cfg.Proxies[liveProbeGroup]
	if !exists || proxy == nil {
		current.mu.RUnlock()
		return errors.New("nozelt core: live proxy group is missing")
	}
	testContext, finish, accepted := registerDelayTest(testGeneration)
	current.mu.RUnlock()
	if !accepted {
		return errors.New("nozelt core: live probe cancelled")
	}
	defer finish()

	total := time.Duration(timeoutMs) * time.Millisecond
	attempt := total / 2
	if attempt > 2500*time.Millisecond {
		attempt = 2500 * time.Millisecond
	}
	ctx, cancel := context.WithTimeout(testContext, total)
	defer cancel()
	urls := delayProbeURLs("")
	var lastErr error
	for _, candidate := range urls {
		if ctx.Err() != nil {
			break
		}
		attemptCtx, attemptCancel := context.WithTimeout(ctx, attempt)
		_, err := measureProxyDelayOnce(attemptCtx, proxy, candidate)
		attemptCancel()
		if err == nil {
			return nil
		}
		lastErr = err
	}
	if lastErr == nil {
		lastErr = ctx.Err()
	}
	logger.Warn("nozelt core: live connection probe failed (" + classifyDelayError(lastErr) + ")")
	return errors.New("nozelt core: live connection probe failed")
}

// startTemporaryDelayRuntime initializes mihomo without TUN or any local
// listener, giving transports such as HY2+Gecko the same setup they receive in
// a real session. It is used for a fully stopped VPN and for profiles running
// through Xray/sing-box. It deliberately rejects plaintext/system/bootstrap
// DNS: manual ping may reveal the proxy IP to the underlay, never its hostname.
func startTemporaryDelayRuntime(parsed *parsedConfig) (func(), error) {
	cfg := parsed.cfg.DNS
	if cfg == nil || !cfg.Enable || len(cfg.ProxyServerNameserver) == 0 {
		return nil, fmt.Errorf("delay tests require encrypted DNS")
	}
	secureNameservers := func(nameservers []mdns.NameServer) bool {
		if len(nameservers) == 0 {
			return false
		}
		for _, nameserver := range nameservers {
			if nameserver.ProxyName != "" {
				return false
			}
			switch nameserver.Net {
			case "https":
				parsed, err := url.Parse(nameserver.Addr)
				if err != nil || parsed.Scheme != "https" || parsed.Host == "" {
					return false
				}
			case "tls", "quic":
				if strings.TrimSpace(nameserver.Addr) == "" {
					return false
				}
			default:
				return false
			}
		}
		return true
	}
	if !secureNameservers(cfg.DefaultNameserver) ||
		!secureNameservers(cfg.ProxyServerNameserver) {
		return nil, fmt.Errorf("delay tests require encrypted DNS")
	}
	for _, policy := range cfg.ProxyServerPolicy {
		if !secureNameservers(policy.NameServers) {
			return nil, fmt.Errorf("delay tests require encrypted DNS")
		}
	}

	// Reuse the strict TUN ingress validator as a generic "no listener"
	// assertion, then turn TUN off before ApplyConfig so no fd/device is needed.
	parsed.cfg.General.Tun.Enable = true
	if err := validateTunOnlyPrivacy(parsed.cfg); err != nil {
		parsed.cfg.General.Tun.Enable = false
		return nil, fmt.Errorf("delay runtime must not expose listeners")
	}
	parsed.cfg.General.Tun.Enable = false
	parsed.cfg.General.Tun.FileDescriptor = 0

	temporaryDelayRuntimeMu.Lock()
	if err := applyConfig(parsed); err != nil {
		// applyConfig errors contain only listener names/counts or the selected
		// TUN stack, never profile endpoints or credentials.
		logger.Warn("nozelt core: temporary delay runtime init failed: " + err.Error())
		cleanupTemporaryDelayRuntime()
		temporaryDelayRuntimeMu.Unlock()
		return nil, fmt.Errorf("could not initialize delay runtime")
	}

	var once sync.Once
	return func() {
		once.Do(func() {
			cleanupTemporaryDelayRuntime()
			temporaryDelayRuntimeMu.Unlock()
		})
	}, nil
}

func cleanupTemporaryDelayRuntime() {
	_ = closeTrackedConnections()
	resolver.ResetConnection()
	shutdownMihomo()
	resolver.ClearCache()
	_ = resolver.FlushFakeIP()
	resolver.DefaultResolver = nil
	resolver.DefaultHostMapper = nil
	resolver.DefaultService = nil
	resolver.ProxyServerHostResolver = nil
	resolver.DirectHostResolver = nil
	mtunnel.UpdateProxies(map[string]C.Proxy{}, map[string]P.ProxyProvider{})
	mtunnel.UpdateRules(nil, nil, nil)
	mtunnel.UpdateListeners(map[string]C.InboundListener{})
}

func delayTestGeneration() uint64 {
	activeDelayTests.Lock()
	defer activeDelayTests.Unlock()
	return activeDelayTests.generation
}

// CancelDelayTests stops foreground/UI-owned URL tests without disturbing the
// live VPN. Taking the core write lock prevents a new test from registering
// between cancellation and the wait barrier. Lifecycle operations call the
// lower-level helper directly because they already hold this lock.
func CancelDelayTests() {
	current.mu.Lock()
	defer current.mu.Unlock()
	cancelAndWaitDelayTests()
}

// cancelAndWaitDelayTests is called while current.mu is write-locked. No new
// test can register until the lifecycle operation finishes. Per-node contexts
// inherit these cancellations, bounding the wait by the transport test timeout.
func cancelAndWaitDelayTests() {
	activeDelayTests.Lock()
	activeDelayTests.generation++
	for _, cancel := range activeDelayTests.cancels {
		cancel()
	}
	activeDelayTests.Unlock()
	activeDelayTests.wait.Wait()
}

func marshalDelayEnvelope(envelope delayEnvelope) string {
	raw, err := json.Marshal(envelope)
	if err != nil {
		return fmt.Sprintf(`{"ok":false,"error":%q}`, err.Error())
	}
	return string(raw)
}
