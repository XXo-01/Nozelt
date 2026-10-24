//go:build windows

package main

import (
	"encoding/json"
	"testing"
)

func safeFrontendFixture() map[string]any {
	var value map[string]any
	json.Unmarshal([]byte(`{"mode":"rule","tun":{"enable":true,"auto-route":true,"auto-detect-interface":true,"strict-route":true,"device":"Nozelt","dns-hijack":["udp://any:53","tcp://any:53"]},"dns":{"enable":true,"enhanced-mode":"fake-ip","nameserver":["https://1.1.1.1/dns-query#PROXY"],"direct-nameserver":["https://1.1.1.1/dns-query#PROXY"],"default-nameserver":["https://1.1.1.1/dns-query"],"proxy-server-nameserver":["https://1.1.1.1/dns-query"]},"proxy-groups":[{"name":"PROXY","proxies":["server"]}]}`), &value)
	return value
}
func TestWindowsPolicyRejectsAccidentalBypasses(t *testing.T) {
	if err := validateWindowsFrontend(safeFrontendFixture()); err != nil {
		t.Fatal(err)
	}
	cases := map[string]func(map[string]any){
		"plaintext DNS": func(v map[string]any) { v["dns"].(map[string]any)["nameserver"] = []any{"udp://1.1.1.1#PROXY"} },
		"system DNS":    func(v map[string]any) { v["dns"].(map[string]any)["default-nameserver"] = []any{"system"} },
		"DIRECT DNS": func(v map[string]any) {
			v["dns"].(map[string]any)["direct-nameserver"] = []any{"https://1.1.1.1/dns-query"}
		},
		"DNS bootstrap hostname": func(v map[string]any) {
			v["dns"].(map[string]any)["proxy-server-nameserver"] = []any{"https://dns.test/dns-query"}
		},
		"TCP DNS missed":           func(v map[string]any) { v["tun"].(map[string]any)["dns-hijack"] = []any{"udp://any:53"} },
		"strict route off":         func(v map[string]any) { v["tun"].(map[string]any)["strict-route"] = false },
		"DIRECT selector fallback": func(v map[string]any) { v["proxy-groups"].([]any)[0].(map[string]any)["proxies"] = []any{"DIRECT"} },
		"public controller":        func(v map[string]any) { v["external-controller"] = "0.0.0.0:9090" },
		"local proxy port":         func(v map[string]any) { v["mixed-port"] = float64(7890) },
		"plaintext fallback":       func(v map[string]any) { v["dns"].(map[string]any)["fallback"] = []any{"1.1.1.1"} },
		"fallback bypass": func(v map[string]any) {
			v["dns"].(map[string]any)["fallback"] = []any{"https://1.1.1.1/dns-query#DIRECT"}
		},
		"policy bypass": func(v map[string]any) {
			v["dns"].(map[string]any)["nameserver-policy"] = map[string]any{"+.example.test": []any{"https://1.1.1.1/dns-query"}}
		},
		"policy ECS": func(v map[string]any) {
			v["dns"].(map[string]any)["nameserver-policy"] = map[string]any{"+.example.test": []any{"https://1.1.1.1/dns-query#PROXY&ecs=1.2.3.0/24"}}
		},
		"bootstrap through itself": func(v map[string]any) {
			v["dns"].(map[string]any)["proxy-server-nameserver-policy"] = map[string]any{"vpn.example.test": []any{"https://1.1.1.1/dns-query#PROXY"}}
		},
		"loopback resolver": func(v map[string]any) {
			v["dns"].(map[string]any)["nameserver"] = []any{"https://127.0.0.1/dns-query#PROXY"}
		},
		"route bypass": func(v map[string]any) { v["tun"].(map[string]any)["route-exclude-address"] = []any{"0.0.0.0/0"} },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			value := safeFrontendFixture()
			mutate(value)
			if validateWindowsFrontend(value) == nil {
				t.Fatal("unsafe policy accepted")
			}
		})
	}
	if _, err := windowsFrontend(runtimeXray, `{"inbounds":[{"protocol":"tun"}]}`); err == nil {
		t.Fatal("unprotected legacy TUN accepted")
	}
}

func TestRoutingReloadKeepsInstalledNetworkPolicy(t *testing.T) {
	previous := safeFrontendFixture()
	next := safeFrontendFixture()
	next["rules"] = []any{"DOMAIN,example.test,DIRECT", "MATCH,PROXY"}
	if err := validateRoutingOnlyReload(previous, next); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"ipv6", "tun"} {
		candidate := safeFrontendFixture()
		candidate[key] = true
		if validateRoutingOnlyReload(previous, candidate) == nil {
			t.Fatal("network policy changed through rules-only reload", key)
		}
	}
}

func TestWindowsRejectsUnverifiedTLS(t *testing.T) {
	for _, key := range []string{"skip-cert-verify", "allowInsecure", "insecure"} {
		if requireVerifiedTLS([]any{map[string]any{"tls": map[string]any{key: true}}}) == nil {
			t.Fatal("insecure TLS accepted", key)
		}
	}
	if requireVerifiedTLS(map[string]any{"tls": map[string]any{"insecure": false}}) != nil {
		t.Fatal("verified TLS rejected")
	}
}

func TestWindowsRejectsLostProviderSourceContext(t *testing.T) {
	for _, key := range []string{"process_name", "source_ip_cidr", "source_port", "inbound", "auth_user"} {
		if requireOriginalProcessContext(map[string]any{"rules": []any{map[string]any{key: []any{"fixture"}}}}) == nil {
			t.Fatal("lost source context accepted", key)
		}
	}
	for _, key := range []string{"source", "sourcePort", "user", "inboundTag"} {
		if requireXraySourceContext(map[string]any{"rules": []any{map[string]any{key: []any{"fixture"}}}}) == nil {
			t.Fatal("lost Xray source context accepted", key)
		}
	}
	if err := requireXraySourceContext(map[string]any{"rules": []any{map[string]any{"inboundTag": []any{"nozelt-endpoint-dns", "nozelt-internal-dns"}}}}); err != nil {
		t.Fatal("internal DNS identity rejected", err)
	}
}
