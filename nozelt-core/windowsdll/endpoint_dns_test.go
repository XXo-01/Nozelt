//go:build windows

package main

import (
	"strings"
	"testing"
)

func TestNativeEndpointDNSPolicyIsNotIgnored(t *testing.T) {
	for _, kind := range []string{runtimeXray, runtimeSingBox} {
		t.Run(kind, func(t *testing.T) {
			frontend := safeFrontendFixture()
			frontend["proxies"] = []any{map[string]any{"name": "server", "type": "socks5", "server": "127.0.0.1", "port": float64(1)}}
			frontend["proxy-groups"].([]any)[0].(map[string]any)["type"] = "select"
			frontend["dns"].(map[string]any)["proxy-server-nameserver-policy"] = map[string]any{"+.example.test": []any{"https://9.9.9.9/dns-query"}}
			var outbound map[string]any
			if kind == runtimeXray {
				outbound = map[string]any{"protocol": "vless", "settings": map[string]any{"vnext": []any{map[string]any{"address": "vpn.example.test"}}}}
			} else {
				outbound = map[string]any{"type": "vless", "server": "vpn.example.test"}
			}
			document := map[string]any{"dns": map[string]any{"servers": []any{
				map[string]any{"address": "https://1.1.1.1/dns-query", "tag": "nozelt-endpoint-dns", "domains": []any{"full:vpn.example.test"}},
			}}, "outbounds": []any{outbound}}
			relay := relayConfig{Frontend: frontend}
			if err := relay.applyEndpointDNSPolicies(kind, document); err != nil {
				t.Fatal(err)
			}
			servers := document["dns"].(map[string]any)["servers"].([]any)
			if kind == runtimeXray {
				if len(servers) != 1 || !strings.Contains(servers[0].(map[string]any)["address"].(string), "9.9.9.9") {
					t.Fatal("Xray policy was ignored or raced default bootstrap")
				}
			} else {
				if outbound["domain_resolver"] != "endpoint-policy-0" || servers[len(servers)-1].(map[string]any)["server"] != "9.9.9.9" {
					t.Fatal("sing-box policy was ignored")
				}
			}
		})
	}
}
