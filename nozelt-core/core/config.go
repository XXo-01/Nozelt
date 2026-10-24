package core

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"runtime"
	"sort"
	"strings"

	mconfig "github.com/metacubex/mihomo/config"

	"github.com/nozelt/nozelt-core/logger"
)

const maxConfigBytes = 32 * 1024 * 1024

// parsedConfig is the validated form of a user-supplied mihomo YAML
// configuration. It holds both the raw bytes (kept for re-application during
// hot reload introspection) and the structured *config.Config that the
// mihomo executor wants to consume.
//
// The embedded mihomo type is deliberately not exposed outside this package
// so callers do not become tied to a specific mihomo version.
type parsedConfig struct {
	raw            []byte
	cfg            *mconfig.Config
	proxySignature [sha256.Size]byte
}

// parseConfig validates configYAML and parses it into mihomo's internal
// configuration tree. Empty input is rejected explicitly before handing off
// to mihomo so the caller gets a clear, deterministic error instead of one
// of mihomo's many possible parser messages.
//
// Any error returned by mihomo is wrapped with `mihomo parse:` so it is
// distinguishable from our own validation failures further up the stack.
// ValidateConfig parses and disposes a candidate without applying listeners,
// TUN adapters, DNS settings or routes. Bundled geodata must already be present.
func ValidateConfig(configYAML string) error {
	current.mu.Lock()
	defer current.mu.Unlock()
	parsed, err := parseConfig(configYAML)
	if parsed != nil {
		closeProxyAdapters(parsed.cfg)
	}
	return err
}

func parseConfig(configYAML string) (parsed *parsedConfig, err error) {
	var cfg *mconfig.Config
	defer func() {
		if recover() != nil {
			// Parsing can panic after constructing adapters/providers. Release
			// any partial config before collapsing the third-party panic.
			func() {
				defer func() { _ = recover() }()
				closeProxyAdapters(cfg)
			}()
			parsed = nil
			err = errors.New("mihomo parse failed")
			// Third-party panic payloads can contain a complete proxy map.
			// Record only a fixed diagnostic marker.
			logger.Warn("nozelt core: recovered from malformed config")
		}
	}()

	if len(configYAML) > maxConfigBytes {
		return nil, errors.New("config exceeds the safe size limit")
	}

	trimmed := strings.TrimSpace(configYAML)
	if trimmed == "" {
		return nil, errors.New("config is empty")
	}

	rawConfig, parseErr := mconfig.UnmarshalRawConfig([]byte(configYAML))
	if parseErr != nil || rawConfig == nil {
		return nil, errors.New("mihomo parse failed")
	}
	// The pool opens its cache during ParseRawConfig, before executor apply.
	// Set privacy policy here, not after parsing (too late to stop disk I/O).
	rawConfig.Profile.StoreSelected = false
	rawConfig.Profile.StoreFakeIP = rawConfig.Profile.StoreFakeIP && runtime.GOOS == "windows" &&
		rawConfig.Tun.Enable && rawConfig.Tun.AutoRoute
	// Mihomo forwards ping to a real IP DIRECT, outside the proxy and with
	// the user's real address. Android has no separate leak guard, so ping is
	// always answered inside the tunnel there.
	if runtime.GOOS == "android" {
		rawConfig.Tun.DisableICMPForwarding = true
	}
	cfg, parseErr = mconfig.ParseRawConfig(rawConfig)
	if parseErr != nil {
		// Be defensive if a future mihomo parser returns a partially built
		// configuration together with an error. Such a value can already own
		// provider workers or transport resources.
		closeProxyAdapters(cfg)
		// Parser errors are not a stable API and can quote credential-bearing
		// input. Keep the boundary error deterministic and secret-free.
		return nil, errors.New("mihomo parse failed")
	}
	if cfg == nil {
		// Defensive: mihomo currently always returns a non-nil cfg on nil
		// error, but the API contract does not formally guarantee that.
		return nil, errors.New("mihomo parse returned nil config without error")
	}

	// Selected-node persistence stays in Nozelt's encrypted profile store.
	// Fake-IP persistence is off by default; only the Windows frontend can
	// explicitly opt into a cache under portable-data/core.
	if err := validateTunOnlyPrivacy(cfg); err != nil {
		closeProxyAdapters(cfg)
		return nil, err
	}

	proxySignature, signatureErr := proxyConfigSignature([]byte(configYAML))
	if signatureErr != nil {
		// mconfig.Parse has already constructed live-capable proxy/provider
		// objects. A second raw-signature parse failure must release them even
		// though the configuration never reaches executor.ApplyConfig.
		closeProxyAdapters(cfg)
		return nil, errors.New("mihomo parse failed")
	}

	return &parsedConfig{
		raw:            []byte(configYAML),
		cfg:            cfg,
		proxySignature: proxySignature,
	}, nil
}

// validateTunOnlyPrivacy enforces Nozelt's Android ingress contract at the
// native boundary. Flutter already emits zero local ports, but a corrupted or
// future host configuration must not turn a TUN client into a probeable local
// HTTP/SOCKS/controller/DNS/server endpoint. Proxy-only non-TUN configurations
// remain available to core tests and possible tooling; once TUN is enabled,
// every packet must enter through Android VpnService exclusively.
func validateTunOnlyPrivacy(cfg *mconfig.Config) error {
	if cfg == nil || cfg.General == nil || !cfg.General.Tun.Enable {
		return nil
	}
	g := cfg.General
	localInbound := g.Port != 0 || g.SocksPort != 0 || g.RedirPort != 0 ||
		g.TProxyPort != 0 || g.MixedPort != 0 || g.TuicServer.Enable ||
		strings.TrimSpace(g.ShadowSocksConfig) != "" ||
		strings.TrimSpace(g.VmessConfig) != "" || len(cfg.Listeners) != 0 ||
		len(cfg.Tunnels) != 0
	if cfg.DNS != nil && strings.TrimSpace(cfg.DNS.Listen) != "" {
		localInbound = true
	}
	if controller := cfg.Controller; controller != nil {
		localInbound = localInbound ||
			strings.TrimSpace(controller.ExternalController) != "" ||
			strings.TrimSpace(controller.ExternalControllerTLS) != "" ||
			strings.TrimSpace(controller.ExternalControllerUnix) != "" ||
			strings.TrimSpace(controller.ExternalControllerPipe) != "" ||
			strings.TrimSpace(controller.ExternalDohServer) != ""
	}
	if localInbound {
		return errors.New("tun configuration must not expose local inbound services")
	}
	return nil
}

// proxyConfigSignature fingerprints only sections that construct outbound
// adapters. Rule/DNS/TUN edits therefore compare equal and can safely reuse
// the live proxy objects during hot reload, avoiding a new set of HY2/QUIC
// clients and preserving selector state. The digest is never logged.
func proxyConfigSignature(config []byte) ([sha256.Size]byte, error) {
	raw, err := mconfig.UnmarshalRawConfig(config)
	if err != nil {
		return [sha256.Size]byte{}, err
	}
	sections := struct {
		ProxyProvider map[string]map[string]any `json:"proxy-providers"`
		Proxies       []map[string]any          `json:"proxies"`
		ProxyGroups   []map[string]any          `json:"proxy-groups"`
	}{
		ProxyProvider: raw.ProxyProvider,
		Proxies:       raw.Proxy,
		ProxyGroups:   canonicalProxyGroups(raw.ProxyGroup),
	}
	encoded, err := json.Marshal(sections)
	if err != nil {
		return [sha256.Size]byte{}, err
	}
	return sha256.Sum256(encoded), nil
}

// canonicalProxyGroups removes the only irrelevant ordering difference in a
// select group: ConfigBuilder puts the chosen node first so a cold start has
// the correct default. During a live reload the existing selector is reused,
// therefore two select groups with identical membership are the same adapter
// definition even when their first entry differs. Other group types retain
// their original order because fallback/load-balance semantics can depend on
// it.
func canonicalProxyGroups(groups []map[string]any) []map[string]any {
	encoded, err := json.Marshal(groups)
	if err != nil {
		return groups
	}
	var cloned []map[string]any
	if err := json.Unmarshal(encoded, &cloned); err != nil {
		return groups
	}
	for _, group := range cloned {
		if group["type"] != "select" {
			continue
		}
		proxies, ok := group["proxies"].([]any)
		if !ok {
			continue
		}
		sort.SliceStable(proxies, func(i, j int) bool {
			left, leftOK := proxies[i].(string)
			right, rightOK := proxies[j].(string)
			return leftOK && rightOK && left < right
		})
	}
	return cloned
}
