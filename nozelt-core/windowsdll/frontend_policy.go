//go:build windows

package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"net"
	"net/url"
	"strings"
)

// Network/IPv6 changes require a protected restart. A rules-only update must
// not leave the already-installed WFP policy describing a different adapter.
func validateRoutingOnlyReload(previous, next map[string]any) error {
	if previous == nil {
		return errors.New("network policy unavailable; restart required")
	}
	for _, key := range []string{"tun", "ipv6"} {
		a, _ := json.Marshal(previous[key])
		b, _ := json.Marshal(next[key])
		if !bytes.Equal(a, b) {
			return errors.New("network policy change requires restart")
		}
	}
	return nil
}

func windowsFrontend(kind, document string) (map[string]any, error) {
	if len(document) > 32*1024*1024 {
		return nil, errors.New("config exceeds safe size")
	}
	var value map[string]any
	if json.Unmarshal([]byte(document), &value) != nil {
		return nil, errors.New("invalid Windows config")
	}
	if kind == runtimeMihomo {
		return value, nil
	}
	if kind != runtimeXray && kind != runtimeSingBox {
		return nil, errors.New("unsupported core")
	}
	frontend, ok := value["frontend"].(map[string]any)
	if !ok || value["nozeltWindowsRelay"] != float64(1) {
		return nil, errors.New("Windows requires protected relay")
	}
	transport, ok := value["transport"].(map[string]any)
	if !ok {
		return nil, errors.New("invalid Windows transport")
	}
	if err := requireVerifiedTLS(transport["outbounds"]); err != nil {
		return nil, err
	}
	if kind == runtimeSingBox {
		if err := requireOriginalProcessContext(transport["route"]); err != nil {
			return nil, err
		}
	}
	if kind == runtimeXray {
		if err := requireXraySourceContext(transport["routing"]); err != nil {
			return nil, err
		}
	}
	return frontend, nil
}

func requireOriginalProcessContext(value any) error {
	switch object := value.(type) {
	case map[string]any:
		for key, item := range object {
			switch key {
			case "process_name", "process_path", "process_path_regex", "user", "user_id",
				"package_name", "package_name_regex", "source_ip_cidr", "source_ip_is_private", "source_geoip",
				"source_port", "source_port_range", "rule_set_ip_cidr_match_source", "inbound", "auth_user":
				return errors.New("provider process rules must use Nozelt routing")
			}
			if err := requireOriginalProcessContext(item); err != nil {
				return err
			}
		}
	case []any:
		for _, item := range object {
			if err := requireOriginalProcessContext(item); err != nil {
				return err
			}
		}
	}
	return nil
}

func requireXraySourceContext(value any) error {
	switch object := value.(type) {
	case map[string]any:
		for key, item := range object {
			if key == "source" || key == "sourcePort" || key == "user" {
				return errors.New("provider process rules must use Nozelt routing")
			}
			if key == "inboundTag" {
				tags, ok := item.([]any)
				if !ok {
					return errors.New("provider process rules must use Nozelt routing")
				}
				for _, tag := range tags {
					if tag != "nozelt-endpoint-dns" && tag != "nozelt-internal-dns" {
						return errors.New("provider process rules must use Nozelt routing")
					}
				}
			}
			if err := requireXraySourceContext(item); err != nil {
				return err
			}
		}
	case []any:
		for _, item := range object {
			if err := requireXraySourceContext(item); err != nil {
				return err
			}
		}
	}
	return nil
}

func validateWindowsFrontend(value map[string]any) error {
	fail := func() error { return errors.New("unsafe Windows network policy") }
	if err := requireVerifiedTLS(value["proxies"]); err != nil {
		return err
	}
	tun, ok := value["tun"].(map[string]any)
	if !ok || tun["enable"] != true || tun["auto-route"] != true || tun["auto-detect-interface"] != true || tun["strict-route"] != true || tun["device"] != "Nozelt" {
		return fail()
	}
	hijack, ok := tun["dns-hijack"].([]any)
	if !ok {
		return fail()
	}
	udp, tcp := false, false
	for _, item := range hijack {
		udp = udp || item == "udp://any:53"
		tcp = tcp || item == "tcp://any:53"
	}
	if !udp || !tcp || value["mode"] != "rule" {
		return fail()
	}
	dns, ok := value["dns"].(map[string]any)
	if !ok || dns["enable"] != true || (dns["enhanced-mode"] != "fake-ip" && dns["enhanced-mode"] != "redir-host") {
		return fail()
	}
	for _, key := range []string{"nameserver", "direct-nameserver", "default-nameserver", "proxy-server-nameserver"} {
		resolvers, ok := dns[key].([]any)
		if !ok || len(resolvers) == 0 {
			return fail()
		}
		for _, item := range resolvers {
			text, ok := item.(string)
			if !ok {
				return fail()
			}
			if !safeWindowsResolver(text, key == "nameserver" || key == "direct-nameserver") {
				return fail()
			}
		}
	}
	// Optional resolvers/policies must obey the same boundary as the primary
	// DNS list. Otherwise adding a fallback would silently reintroduce leaks.
	if fallback, exists := dns["fallback"]; exists {
		values, ok := fallback.([]any)
		if !ok {
			return fail()
		}
		for _, item := range values {
			text, ok := item.(string)
			if !ok || !safeWindowsResolver(text, true) {
				return fail()
			}
		}
	}
	for _, key := range []string{"nameserver-policy", "proxy-server-nameserver-policy"} {
		if raw, exists := dns[key]; exists {
			policies, ok := raw.(map[string]any)
			if !ok {
				return fail()
			}
			for _, value := range policies {
				if value == "rcode://success" && key == "nameserver-policy" {
					continue
				}
				values, ok := value.([]any)
				if !ok {
					values = []any{value}
				}
				if len(values) == 0 {
					return fail()
				}
				for _, item := range values {
					text, ok := item.(string)
					if !ok || !safeWindowsResolver(text, key == "nameserver-policy") {
						return fail()
					}
				}
			}
		}
	}
	// OS bypass routes conflict with our full capture/kill-switch contract.
	// Explicit DIRECT exceptions belong in routing, where process/domain/IP
	// precedence remains observable and protected.
	for _, key := range []string{"route-address", "route-exclude-address", "inet4-route-address", "inet6-route-address", "inet4-route-exclude-address", "inet6-route-exclude-address", "include-interface", "exclude-interface"} {
		if raw, exists := tun[key]; exists {
			values, ok := raw.([]any)
			if !ok || len(values) != 0 {
				return fail()
			}
		}
	}
	// The shared parser checks all listener/controller/server forms too. These
	// checks run before arming the guard or starting any transport.
	for _, key := range []string{"port", "socks-port", "mixed-port", "redir-port", "tproxy-port"} {
		if number, exists := value[key]; exists && number != float64(0) {
			return fail()
		}
	}
	for _, key := range []string{"external-controller", "external-controller-tls", "external-controller-unix", "external-controller-pipe"} {
		if text, exists := value[key]; exists && text != "" {
			return fail()
		}
	}
	if text, exists := dns["listen"]; exists && text != "" {
		return fail()
	}
	for _, key := range []string{"listeners", "tunnels"} {
		if list, exists := value[key]; exists && list != nil {
			return fail()
		}
	}
	groups, ok := value["proxy-groups"].([]any)
	if !ok {
		return fail()
	}
	proxyFound := false
	for _, entry := range groups {
		group, ok := entry.(map[string]any)
		if !ok {
			return fail()
		}
		if group["name"] != "PROXY" {
			continue
		}
		proxyFound = true
		members, ok := group["proxies"].([]any)
		if !ok || len(members) == 0 {
			return fail()
		}
		for _, member := range members {
			if text, ok := member.(string); !ok || strings.EqualFold(text, "DIRECT") || strings.EqualFold(text, "COMPATIBLE") || strings.EqualFold(text, "PASS") {
				return fail()
			}
		}
	}
	if !proxyFound {
		return fail()
	}
	return nil
}

func safeWindowsResolver(text string, proxy bool) bool {
	u, err := url.Parse(text)
	if err != nil || u.User != nil || u.RawQuery != "" || u.ForceQuery ||
		(u.Scheme != "https" && u.Scheme != "tls" && u.Scheme != "quic") {
		return false
	}
	ip := net.ParseIP(u.Hostname())
	if ip == nil || ip.IsUnspecified() || ip.IsLoopback() || ip.IsMulticast() || ip.IsLinkLocalUnicast() {
		return false
	}
	if u.Scheme == "https" && (u.Path == "" || u.Path == "/") {
		return false
	}
	if u.Scheme != "https" && u.Path != "" {
		return false
	}
	if proxy {
		return u.Fragment == "PROXY"
	}
	return u.Fragment == ""
}

func requireVerifiedTLS(value any) error {
	switch object := value.(type) {
	case map[string]any:
		for key, item := range object {
			switch key {
			case "skip-cert-verify", "allowInsecure", "allow_insecure", "insecure":
				if item == true || item == "true" {
					return errors.New("Windows requires TLS certificate verification")
				}
			}
			if err := requireVerifiedTLS(item); err != nil {
				return err
			}
		}
	case []any:
		for _, item := range object {
			if err := requireVerifiedTLS(item); err != nil {
				return err
			}
		}
	}
	return nil
}
