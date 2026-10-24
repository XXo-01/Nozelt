package core

import (
	"encoding/json"
	"github.com/metacubex/mihomo/component/geodata"
	C "github.com/metacubex/mihomo/constant"
	R "github.com/metacubex/mihomo/rules"
	RC "github.com/metacubex/mihomo/rules/common"
	"net/netip"
	"os"
	"path/filepath"
	"testing"
)

func TestActualRoutingMatcher(t *testing.T) {
	raw := []string{"PROCESS-NAME,steam.exe,DIRECT", "DOMAIN,blocked.test,REJECT", "DOMAIN-SUFFIX,example.test,DIRECT", "DOMAIN-KEYWORD,telemetry,REJECT", "IP-CIDR,203.0.113.0/24,DIRECT,no-resolve", "IP-CIDR6,2001:db8::/32,REJECT,no-resolve", "MATCH,PROXY"}
	var rules []C.Rule
	for _, text := range raw {
		tp, payload, target, params := RC.ParseRulePayload(text, true)
		rule, err := R.ParseRule(tp, payload, target, params, nil)
		if err != nil {
			t.Fatal(err)
		}
		rules = append(rules, rule)
	}
	cases := []struct{ name, host, process, ip, want string }{
		{"process case insensitive", "blocked.test", "STEAM.EXE", "203.0.113.1", "DIRECT"},
		{"process full name required", "blocked.test", "fake-steam.exe", "203.0.113.1", "REJECT"},
		{"exact domain", "blocked.test", "", "198.51.100.1", "REJECT"},
		{"exact domain does not include subdomains", "www.blocked.test", "", "198.51.100.1", "PROXY"},
		{"suffix", "www.example.test", "", "198.51.100.1", "DIRECT"},
		{"suffix boundary", "notexample.test", "", "198.51.100.1", "PROXY"},
		{"keyword", "telemetry.other.test", "", "198.51.100.1", "REJECT"},
		{"IPv4 prefix", "", "", "203.0.113.1", "DIRECT"},
		{"IPv6 prefix", "", "", "2001:db8::1", "REJECT"},
		{"unmatched has no direct fallback", "", "", "198.51.100.1", "PROXY"},
	}
	for _, item := range cases {
		t.Run(item.name, func(t *testing.T) {
			metadata := &C.Metadata{Host: item.host, Process: item.process, DstIP: netip.MustParseAddr(item.ip)}
			got := ""
			for _, rule := range rules {
				if matched, target := rule.Match(metadata, C.RuleMatchHelper{}); matched {
					got = target
					break
				}
			}
			if got != item.want {
				t.Fatalf("route=%q want=%q", got, item.want)
			}
		})
	}
}

func TestUnknownWindowsProcessUsesProxyBeforeDirectFallback(t *testing.T) {
	// Mirrors ConfigBuilder's Windows guard: an owner-less connection must
	// never fall through to a DIRECT rule, but local traffic keeps LAN policy.
	const text = "AND,((PROCESS-NAME-REGEX,^$),(NOT,((OR,((IP-CIDR,127.0.0.0/8,no-resolve),(IP-CIDR,::1/128,no-resolve),(IP-CIDR,10.0.0.0/8,no-resolve),(IP-CIDR,100.64.0.0/10,no-resolve),(IP-CIDR,172.16.0.0/12,no-resolve),(IP-CIDR,192.168.0.0/16,no-resolve),(IP-CIDR,169.254.0.0/16,no-resolve),(IP-CIDR,224.0.0.0/4,no-resolve),(IP-CIDR,255.255.255.255/32,no-resolve),(IP-CIDR,fc00::/7,no-resolve),(IP-CIDR,fe80::/10,no-resolve),(IP-CIDR,ff00::/8,no-resolve)))))),PROXY"
	tp, payload, target, params := RC.ParseRulePayload(text, true)
	rule, err := R.ParseRule(tp, payload, target, params, nil)
	if err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name, process, ip string
		want              bool
	}{
		{"unknown owner to Internet", "", "198.51.100.1", true},
		{"unknown owner to IPv6 Internet", "", "2001:db8::1", true},
		{"unknown owner to LAN", "", "192.168.1.10", false},
		{"unknown owner to loopback", "", "127.0.0.1", false},
		{"known owner", "steam.exe", "198.51.100.1", false},
	}
	for _, item := range cases {
		metadata := &C.Metadata{Process: item.process, DstIP: netip.MustParseAddr(item.ip)}
		matched, adapter := rule.Match(metadata, C.RuleMatchHelper{})
		if matched != item.want || (matched && adapter != "PROXY") {
			t.Fatalf("%s: matched=%v adapter=%q", item.name, matched, adapter)
		}
	}
}
func TestBundledGeoRoutingMatcher(t *testing.T) {
	root := os.Getenv("NOZELT_TEST_GEODATA_DIR")
	if root == "" {
		t.Skip("bundled geodata not supplied; no automatic downloads in tests")
	}
	home, mode := C.Path.HomeDir(), geodata.GeodataMode()
	C.SetHomeDir(root)
	geodata.SetGeodataMode(true)
	defer func() { C.SetHomeDir(home); geodata.SetGeodataMode(mode) }()
	for _, name := range []string{"geoip.dat", "geosite.dat"} {
		if _, err := os.Stat(filepath.Join(root, name)); err != nil {
			t.Fatal(err)
		}
	}
	ip, err := RC.NewGEOIP("cn", "DIRECT", false, true)
	if err != nil {
		t.Fatal(err)
	}
	if match, _ := ip.Match(&C.Metadata{DstIP: netip.MustParseAddr("114.114.114.114")}, C.RuleMatchHelper{}); !match {
		t.Fatal("bundled GEOIP matcher missed CN fixture")
	}
	site, err := RC.NewGEOSITE("google", "PROXY")
	if err != nil {
		t.Fatal(err)
	}
	if match, _ := site.Match(&C.Metadata{Host: "www.google.com"}, C.RuleMatchHelper{}); !match {
		t.Fatal("bundled GEOSITE matcher missed Google fixture")
	}
	if match, _ := site.Match(&C.Metadata{Host: "google.com.attacker.test"}, C.RuleMatchHelper{}); match {
		t.Fatal("GEOSITE hostname boundary bypass")
	}
}

func TestClashImportPreservesRoutingWithoutHostServices(t *testing.T) {
	document := `proxies:
  - {name: test, type: socks5, server: 127.0.0.1, port: 9001}
proxy-groups:
  - {name: PROXY, type: select, proxies: [test]}
rules:
  - DOMAIN,provider.test,REJECT
  - MATCH,PROXY
external-controller: 0.0.0.0:9090
dns: {nameserver: [system]}
`
	var result map[string]any
	if err := json.Unmarshal([]byte(ParseSubscription(document)), &result); err != nil {
		t.Fatal(err)
	}
	if result["ok"] != true {
		t.Fatal("fixture import failed")
	}
	routing, ok := result["providerRouting"].(map[string]any)
	if !ok {
		t.Fatal("provider routing was discarded")
	}
	if len(routing["rules"].([]any)) != 2 || routing["dns"] != nil || routing["external-controller"] != nil {
		t.Fatal("unsafe/incomplete provider snapshot")
	}
}
