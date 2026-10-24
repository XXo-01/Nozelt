package core

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	mconfig "github.com/metacubex/mihomo/config"
)

// Representative real-world share links. Values are dummies but structurally
// valid so mihomo's convert accepts them.
const (
	vlessRealityLink = "vless://b831381d-6324-4d53-ad4f-8cda48b30811@example.com:443" +
		"?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome" +
		"&pbk=xLxbxABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abc&sid=6ba85179e30d4fc2" +
		"&type=tcp&flow=xtls-rprx-vision#Reality-Test"

	hysteria2Link = "hysteria2://letmein@example.com:443?insecure=1&sni=example.com#HY2-Test"

	hysteria2GeckoLink = "hy2://letmein@example.com:443?insecure=1&sni=example.com" +
		"&obfs=gecko&obfs-password=gecko-secret#HY2-Gecko-Test"

	ssLink = "ss://aes-256-gcm:password@1.2.3.4:8388#SS-Test"

	trojanLink = "trojan://secret@example.com:443?sni=example.com#Trojan-Test"
)

func decodeLinkResult(t *testing.T, s string) linkResult {
	t.Helper()
	var r linkResult
	if err := json.Unmarshal([]byte(s), &r); err != nil {
		t.Fatalf("linkResult JSON invalid: %v (%s)", err, s)
	}
	return r
}

func decodeSubResult(t *testing.T, s string) subResult {
	t.Helper()
	var r subResult
	if err := json.Unmarshal([]byte(s), &r); err != nil {
		t.Fatalf("subResult JSON invalid: %v (%s)", err, s)
	}
	return r
}

// TestParseProxyLink_VlessReality confirms a VLESS+Reality link parses and the
// Reality/flow specifics land where the config expects them.
func TestParseProxyLink_VlessReality(t *testing.T) {
	r := decodeLinkResult(t, ParseProxyLink(vlessRealityLink))
	if !r.OK {
		t.Fatalf("vless+reality link = not ok: %q", r.Error)
	}
	if r.Proxy["type"] != "vless" {
		t.Errorf("type = %v, want vless", r.Proxy["type"])
	}
	if r.Proxy["server"] != "example.com" {
		t.Errorf("server = %v, want example.com", r.Proxy["server"])
	}
	if r.Proxy["flow"] != "xtls-rprx-vision" {
		t.Errorf("flow = %v, want xtls-rprx-vision", r.Proxy["flow"])
	}
	ro, ok := r.Proxy["reality-opts"].(map[string]any)
	if !ok {
		t.Fatalf("reality-opts missing or wrong type: %T", r.Proxy["reality-opts"])
	}
	if ro["public-key"] == "" || ro["short-id"] != "6ba85179e30d4fc2" {
		t.Errorf("reality-opts = %v, want public-key set + short-id", ro)
	}
}

// TestParseProxyLink_Hysteria2 covers a non-VLESS protocol path.
func TestParseProxyLink_Hysteria2(t *testing.T) {
	r := decodeLinkResult(t, ParseProxyLink(hysteria2Link))
	if !r.OK {
		t.Fatalf("hysteria2 link = not ok: %q", r.Error)
	}
	if r.Proxy["type"] != "hysteria2" {
		t.Errorf("type = %v, want hysteria2", r.Proxy["type"])
	}
	if r.Proxy["password"] != "letmein" {
		t.Errorf("password = %v, want letmein", r.Proxy["password"])
	}
}

func TestParseProxyLink_V2RayPluginDefaultsToWebSocket(t *testing.T) {
	credentials := base64.RawURLEncoding.EncodeToString(
		[]byte("aes-256-gcm:test-password"),
	)
	link := "ss://" + credentials + "@vpn.example:443" +
		"?plugin=v2ray-plugin%3Btls%3Bhost%3Dcdn.example%3Bpath%3D%2Fws%3Bmux%3D0" +
		"#SS-V2Ray-Plugin"

	result := decodeLinkResult(t, ParseProxyLink(link))
	if !result.OK {
		t.Fatalf("v2ray-plugin link = not ok: %q", result.Error)
	}
	options, ok := result.Proxy["plugin-opts"].(map[string]any)
	if !ok {
		t.Fatalf("plugin options missing or wrong type: %T", result.Proxy["plugin-opts"])
	}
	if options["mode"] != "websocket" {
		t.Fatalf("plugin mode = %q, want websocket", options["mode"])
	}

	config := map[string]any{
		"mixed-port": 0,
		"mode":       "rule",
		"proxies":    []map[string]any{result.Proxy},
		"proxy-groups": []map[string]any{{
			"name":    "PROXY",
			"type":    "select",
			"proxies": []string{result.Proxy["name"].(string)},
		}},
		"rules": []string{"MATCH,PROXY"},
	}
	encoded, err := json.Marshal(config)
	if err != nil {
		t.Fatalf("marshal v2ray-plugin config: %v", err)
	}
	if _, err := mconfig.Parse(encoded); err != nil {
		t.Fatalf("mihomo rejected defaulted v2ray-plugin config: %v", err)
	}
}

// TestParseProxyLink_Hysteria2Gecko protects the minimum mihomo version
// required by Nozelt: v1.19.26 introduced Gecko obfuscation support. The
// share-link converter must preserve the Gecko fields, and the resulting
// proxy map must be accepted by mihomo's config parser.
func TestParseProxyLink_Hysteria2Gecko(t *testing.T) {
	r := decodeLinkResult(t, ParseProxyLink(hysteria2GeckoLink))
	if !r.OK {
		t.Fatalf("hysteria2+gecko link = not ok: %q", r.Error)
	}
	if r.Proxy["type"] != "hysteria2" {
		t.Errorf("type = %v, want hysteria2", r.Proxy["type"])
	}
	if r.Proxy["obfs"] != "gecko" {
		t.Errorf("obfs = %v, want gecko", r.Proxy["obfs"])
	}
	if r.Proxy["obfs-password"] != "gecko-secret" {
		t.Errorf("obfs-password = %v, want gecko-secret", r.Proxy["obfs-password"])
	}

	cfg := map[string]any{
		"mixed-port": 7890,
		"mode":       "rule",
		"proxies":    []map[string]any{r.Proxy},
		"proxy-groups": []map[string]any{
			{
				"name":    "PROXY",
				"type":    "select",
				"proxies": []string{r.Proxy["name"].(string), "DIRECT"},
			},
		},
		"rules": []string{"MATCH,PROXY"},
	}
	buf, err := json.Marshal(cfg)
	if err != nil {
		t.Fatalf("marshal gecko config: %v", err)
	}
	if _, err := mconfig.Parse(buf); err != nil {
		t.Fatalf("mihomo rejected hysteria2+gecko config: %v", err)
	}
}

// TestParseProxyLink_Garbage must fail gracefully (ok:false), never panic.
func TestParseProxyLink_Garbage(t *testing.T) {
	for _, g := range []string{"not-a-link", "://///", "wireguard://nope", "   ", "vless://"} {
		r := decodeLinkResult(t, ParseProxyLink(g))
		if r.OK {
			t.Errorf("garbage %q parsed as ok, want ok:false", g)
		}
	}
}

func TestParseErrorsDoNotEchoCredentialBearingInput(t *testing.T) {
	const marker = "nozelt-super-secret-marker"
	link := decodeLinkResult(t, ParseProxyLink("vless://"+marker))
	if strings.Contains(link.Error, marker) {
		t.Fatalf("proxy parse error exposed input: %q", link.Error)
	}

	subscription := decodeSubResult(t, ParseSubscription("invalid "+marker))
	if strings.Contains(subscription.Error, marker) {
		t.Fatalf("subscription parse error exposed input: %q", subscription.Error)
	}
}

func TestParseInputLimits(t *testing.T) {
	link := decodeLinkResult(t, ParseProxyLink(strings.Repeat("x", maxProxyLinkBytes+1)))
	if link.OK || !strings.Contains(link.Error, "size limit") {
		t.Fatalf("oversized link result = %#v", link)
	}

	subscription := decodeSubResult(
		t,
		ParseSubscription(strings.Repeat("x", maxSubscriptionBytes+1)),
	)
	if subscription.OK || !strings.Contains(subscription.Error, "size limit") {
		t.Fatalf("oversized subscription result = %#v", subscription)
	}
}

func TestParseSubscriptionRejectsExcessiveProxyCount(t *testing.T) {
	var yaml strings.Builder
	yaml.WriteString("proxies:\n")
	for i := 0; i <= maxSubscriptionProxies; i++ {
		fmt.Fprintf(
			&yaml,
			"  - {name: node-%d, type: ss, server: 192.0.2.1, port: 8388, cipher: aes-256-gcm, password: test}\n",
			i,
		)
	}

	result := decodeSubResult(t, ParseSubscription(yaml.String()))
	if result.OK || !strings.Contains(result.Error, "too many proxies") {
		t.Fatalf("excessive proxy result = ok:%v count:%d error:%q", result.OK, result.Count, result.Error)
	}
}

// TestParseSubscription_Base64 covers the base64-encoded link-list format.
func TestParseSubscription_Base64(t *testing.T) {
	raw := strings.Join([]string{vlessRealityLink, hysteria2Link, ssLink}, "\n")
	encoded := base64.StdEncoding.EncodeToString([]byte(raw))

	r := decodeSubResult(t, ParseSubscription(encoded))
	if !r.OK {
		t.Fatalf("base64 subscription = not ok: %q", r.Error)
	}
	if r.Count != 3 || len(r.Proxies) != 3 {
		t.Errorf("count = %d, want 3", r.Count)
	}
}

// TestParseSubscription_PlainList covers a plaintext (non-base64) link list.
func TestParseSubscription_PlainList(t *testing.T) {
	raw := strings.Join([]string{trojanLink, ssLink}, "\n")
	r := decodeSubResult(t, ParseSubscription(raw))
	if !r.OK || r.Count != 2 {
		t.Fatalf("plain list = ok:%v count:%d, want ok:true count:2 (%q)", r.OK, r.Count, r.Error)
	}
}

// TestParseSubscription_ClashYaml covers a ready Clash/mihomo YAML document,
// which must be detected and routed through the YAML parser (not the link
// parser).
func TestParseSubscription_ClashYaml(t *testing.T) {
	yaml := `
proxies:
  - name: ss-1
    type: ss
    server: 1.2.3.4
    port: 8388
    cipher: aes-256-gcm
    password: password
  - name: tr-1
    type: trojan
    server: example.com
    port: 443
    password: secret
    sni: example.com
`
	r := decodeSubResult(t, ParseSubscription(yaml))
	if !r.OK {
		t.Fatalf("clash yaml = not ok: %q", r.Error)
	}
	if r.Count != 2 {
		t.Errorf("count = %d, want 2", r.Count)
	}
}

func TestParseSubscription_HappXrayBalancer(t *testing.T) {
	document := `{
	  "remarks": "Auto | Europe | WIFI",
	  "burstObservatory": {
	    "pingConfig": {
	      "destination": "http://www.gstatic.com/generate_204",
	      "interval": "20s"
	    },
	    "subjectSelector": ["proxy"]
	  },
	  "outbounds": [
	    {
	      "protocol": "vless",
	      "tag": "proxy",
	      "settings": {"vnext": [{"address": "one.example", "port": 443, "users": [{"id": "11111111-1111-4111-8111-111111111111", "encryption": "none"}]}]},
	      "streamSettings": {"network": "grpc", "security": "tls", "grpcSettings": {"serviceName": "grpc"}, "tlsSettings": {"serverName": "one.example", "fingerprint": "firefox"}}
	    },
	    {
	      "protocol": "vless",
	      "tag": "proxy-2",
	      "settings": {"vnext": [{"address": "two.example", "port": 7443, "users": [{"id": "22222222-2222-4222-8222-222222222222", "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
	      "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "two.example", "fingerprint": "firefox"}}
	    },
	    {"protocol": "freedom", "tag": "direct"}
	  ],
	  "routing": {
	    "balancers": [{"tag": "EU_BALANCER", "selector": ["proxy"], "strategy": {"type": "leastLoad"}}],
	    "rules": [{"balancerTag": "EU_BALANCER", "network": "tcp,udp", "type": "field"}]
	  }
	}`
	result := decodeSubResult(t, ParseSubscription(document))
	if !result.OK || result.Count != 1 {
		t.Fatalf("Happ balancer = ok:%v count:%d error:%q", result.OK, result.Count, result.Error)
	}
	if result.SuggestedCore != "xray" {
		t.Fatalf("suggested core = %q, want xray", result.SuggestedCore)
	}
	automatic := result.Proxies[0]
	if automatic["name"] != "Auto | Europe | WIFI" || automatic["type"] != "url-test" {
		t.Fatalf("unexpected automatic proxy: %#v", automatic)
	}
	members, ok := automatic["nozelt-auto-members"].([]any)
	if !ok || len(members) != 2 {
		t.Fatalf("automatic members = %#v", automatic["nozelt-auto-members"])
	}
	if _, ok := automatic["nozelt-native-config"].(map[string]any); !ok {
		t.Fatal("complete Xray document was not preserved")
	}
	if automatic["nozelt-auto-url"] != "http://www.gstatic.com/generate_204" {
		t.Fatalf("automatic test URL = %q", automatic["nozelt-auto-url"])
	}
	proxyMaps := make([]map[string]any, 0, len(members))
	memberNames := make([]string, 0, len(members))
	for _, rawMember := range members {
		member, ok := rawMember.(map[string]any)
		if !ok {
			t.Fatalf("automatic member type = %T", rawMember)
		}
		proxyMaps = append(proxyMaps, member)
		memberNames = append(memberNames, member["name"].(string))
	}
	config := map[string]any{
		"mixed-port": 0,
		"mode":       "rule",
		"proxies":    proxyMaps,
		"proxy-groups": []map[string]any{
			{
				"name":      automatic["name"],
				"type":      "url-test",
				"proxies":   memberNames,
				"url":       automatic["nozelt-auto-url"],
				"interval":  20,
				"tolerance": 100,
				"lazy":      false,
			},
			{
				"name":    "PROXY",
				"type":    "select",
				"proxies": []any{automatic["name"]},
			},
		},
		"rules": []string{"MATCH,PROXY"},
	}
	encoded, err := json.Marshal(config)
	if err != nil {
		t.Fatalf("marshal translated automatic config: %v", err)
	}
	if _, err := mconfig.Parse(encoded); err != nil {
		t.Fatalf("mihomo rejected translated automatic config: %v", err)
	}
}

func TestParseSubscription_HappSingleRetainsProviderDelayURL(t *testing.T) {
	document := `{
	  "remarks": "Whitelist node",
	  "burstObservatory": {
	    "pingConfig": {
	      "destination": "http://www.gstatic.com/generate_204",
	      "interval": "30s"
	    }
	  },
	  "outbounds": [{
	    "protocol": "vless",
	    "tag": "proxy",
	    "settings": {"vnext": [{"address": "one.example", "port": 443, "users": [{"id": "11111111-1111-4111-8111-111111111111", "encryption": "none"}]}]},
	    "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "one.example"}}
	  }]
	}`
	result := decodeSubResult(t, ParseSubscription(document))
	if !result.OK || result.Count != 1 {
		t.Fatalf("single Happ node = ok:%v count:%d error:%q", result.OK, result.Count, result.Error)
	}
	node := result.Proxies[0]
	if node["nozelt-auto-url"] != "http://www.gstatic.com/generate_204" {
		t.Fatalf("delay URL = %q", node["nozelt-auto-url"])
	}
	if node["nozelt-auto-interval"] != float64(30) {
		t.Fatalf("delay interval = %#v", node["nozelt-auto-interval"])
	}
}

func TestParseSubscription_HappXrayHysteriaDirectSettings(t *testing.T) {
	document := `{
	  "remarks": "Sweden 3 | Ultra",
	  "dns": {"servers": ["77.88.8.8"]},
	  "outbounds": [
	    {
	      "protocol": "hysteria",
	      "tag": "proxy",
	      "settings": {
	        "address": "sweden-three.example",
	        "port": 9443,
	        "version": 2
	      },
	      "streamSettings": {
	        "network": "hysteria",
	        "security": "tls",
	        "hysteriaSettings": {"version": 2, "auth": "test-auth"},
	        "tlsSettings": {
	          "serverName": "sweden-three.example",
	          "allowInsecure": false
	        }
	      }
	    },
	    {"protocol": "freedom", "tag": "direct"},
	    {"protocol": "blackhole", "tag": "block"}
	  ],
	  "routing": {
	    "rules": [
	      {"type": "field", "network": "tcp,udp", "outboundTag": "proxy"}
	    ]
	  }
	}`

	result := decodeSubResult(t, ParseSubscription(document))
	if !result.OK || result.Count != 1 {
		t.Fatalf("Happ Hysteria = ok:%v count:%d error:%q", result.OK, result.Count, result.Error)
	}
	if result.SuggestedCore != "xray" {
		t.Fatalf("suggested core = %q, want xray", result.SuggestedCore)
	}
	proxy := result.Proxies[0]
	if proxy["name"] != "Sweden 3 | Ultra" ||
		proxy["type"] != "hysteria2" ||
		proxy["server"] != "sweden-three.example" ||
		proxy["port"] != float64(9443) {
		t.Fatalf("unexpected Hysteria proxy: %#v", proxy)
	}
	if proxy["password"] != "test-auth" || proxy["sni"] != "sweden-three.example" {
		t.Fatalf("Hysteria metadata was not retained: %#v", proxy)
	}
	if _, ok := proxy["nozelt-native-config"].(map[string]any); !ok {
		t.Fatal("complete Xray Hysteria document was not preserved")
	}
}

func TestParseSubscription_SingBoxDocument(t *testing.T) {
	document := `{
	  "outbounds": [
	    {"type":"selector","tag":"proxy","outbounds":["nl-1"]},
	    {"type":"vless","tag":"nl-1","server":"nl.example","server_port":443,
	     "uuid":"11111111-1111-4111-8111-111111111111"},
	    {"type":"direct","tag":"direct"}
	  ],
	  "route":{"final":"proxy"}
	}`
	result := decodeSubResult(t, ParseSubscription(document))
	if !result.OK || result.Count != 1 {
		t.Fatalf("sing-box config = ok:%v count:%d error:%q", result.OK, result.Count, result.Error)
	}
	if result.SuggestedCore != "sing_box" {
		t.Fatalf("suggested core = %q, want sing_box", result.SuggestedCore)
	}
	proxy := result.Proxies[0]
	if proxy["name"] != "nl-1" || proxy["server"] != "nl.example" {
		t.Fatalf("unexpected sing-box proxy: %#v", proxy)
	}
	if _, ok := proxy["nozelt-native-config"].(map[string]any); !ok {
		t.Fatal("complete sing-box document was not preserved")
	}
}

func TestParseSubscriptionExtractsProfileMetadata(t *testing.T) {
	yaml := `
description: "Солнечного дня"
telegram: "https://t.me/kraken_vpn"
proxies:
  - name: Finland
    type: hysteria2
    server: vpn.example
    port: 443
    password: secret
proxy-groups:
  - name: "☠️ KRAKEN VPN"
    type: select
    proxies:
      - Finland
rules:
  - MATCH,☠️ KRAKEN VPN
`
	r := decodeSubResult(t, ParseSubscription(yaml))
	if !r.OK {
		t.Fatalf("metadata subscription = not ok: %q", r.Error)
	}
	if r.ProfileName != "☠️ KRAKEN VPN" {
		t.Fatalf("profile name = %q", r.ProfileName)
	}
	if r.Description != "Солнечного дня" {
		t.Fatalf("description = %q", r.Description)
	}
	if r.WebPageURL != "https://t.me/kraken_vpn" {
		t.Fatalf("web page = %q", r.WebPageURL)
	}
}

func TestParseSubscriptionFiltersDirectPseudoProxy(t *testing.T) {
	yaml := `
proxies:
  - name: unsafe-bypass
    type: direct
  - name: safe-remote
    type: ss
    server: 1.2.3.4
    port: 8388
    cipher: aes-256-gcm
    password: password
`
	r := decodeSubResult(t, ParseSubscription(yaml))
	if !r.OK || r.Count != 1 {
		t.Fatalf("filtered subscription = ok:%v count:%d error:%q", r.OK, r.Count, r.Error)
	}
	if r.Proxies[0]["name"] != "safe-remote" {
		t.Fatalf("unexpected retained proxy: %#v", r.Proxies[0])
	}

	directOnly := decodeSubResult(t, ParseSubscription("proxies:\n  - {name: bypass, type: direct}\n"))
	if directOnly.OK || !strings.Contains(directOnly.Error, "no usable remote proxies") {
		t.Fatalf("direct-only subscription was accepted: %#v", directOnly)
	}
}

// TestParseSubscription_Empty and garbage → ok:false, no panic.
func TestFilterUsableImportedProxiesRejectsMalformedEndpoints(t *testing.T) {
	proxies := []map[string]any{
		{"name": "missing server", "type": "ss", "port": 443},
		{"name": "missing port", "type": "ss", "server": "vpn.example"},
		{"name": "bad port", "type": "ss", "server": "vpn.example", "port": 70000},
		{"name": "control", "type": "ss", "server": "vpn.example\nleak", "port": 443},
		{"name": "valid", "type": "ss", "server": "vpn.example", "port": 443},
	}

	usable := filterUsableImportedProxies(proxies)
	if len(usable) != 1 || usable[0]["name"] != "valid" {
		t.Fatalf("malformed endpoint filter retained %#v", usable)
	}
}

func TestParseSubscription_Bad(t *testing.T) {
	for _, s := range []string{"", "   \n  ", "this is not a subscription at all"} {
		r := decodeSubResult(t, ParseSubscription(s))
		if r.OK {
			t.Errorf("bad subscription %q parsed as ok", s)
		}
	}
}

// TestJSONConfigParsesAsYAML is the linchpin for the Layer-3 config_builder
// approach: it emits the mihomo config as JSON (which is valid YAML), so this
// verifies mihomo's config.Parse accepts a JSON document with real proxies.
func TestJSONConfigParsesAsYAML(t *testing.T) {
	// Build a config the way config_builder will: a map with injected proxies.
	linkRes := decodeLinkResult(t, ParseProxyLink(ssLink))
	if !linkRes.OK {
		t.Fatalf("prep: ss link did not parse")
	}

	cfg := map[string]any{
		"mixed-port": 7890,
		"mode":       "rule",
		"log-level":  "info",
		"proxies":    []map[string]any{linkRes.Proxy},
		"proxy-groups": []map[string]any{
			{
				"name":    "PROXY",
				"type":    "select",
				"proxies": []string{linkRes.Proxy["name"].(string), "DIRECT"},
			},
		},
		"rules": []string{"MATCH,PROXY"},
	}
	buf, err := json.Marshal(cfg)
	if err != nil {
		t.Fatalf("marshal cfg: %v", err)
	}

	parsed, err := mconfig.Parse(buf)
	if err != nil {
		t.Fatalf("mihomo failed to parse JSON-as-YAML config: %v", err)
	}
	if parsed.General == nil {
		t.Fatal("parsed config has nil General")
	}
	if _, ok := parsed.Proxies[linkRes.Proxy["name"].(string)]; !ok {
		t.Errorf("parsed config missing injected proxy %q", linkRes.Proxy["name"])
	}
}

// TestGeneratedConfigStructureParses mirrors exactly what the Dart
// config_builder emits: TUN-only ingress, encrypted fake-IP DNS, the optional
// bounded domain sniffer, one explicit selector, private-range policy and a
// fail-closed MATCH. This catches Dart/native schema drift before hardware use.
func TestGeneratedConfigStructureParses(t *testing.T) {
	sub := decodeSubResult(t, ParseSubscription(strings.Join([]string{ssLink, trojanLink}, "\n")))
	if !sub.OK || sub.Count != 2 {
		t.Fatalf("prep: subscription did not parse (%q)", sub.Error)
	}
	names := make([]string, 0, len(sub.Proxies))
	for _, p := range sub.Proxies {
		names = append(names, p["name"].(string))
	}

	cfg := map[string]any{
		"port":                0,
		"socks-port":          0,
		"mixed-port":          0,
		"external-controller": "",
		"bind-address":        "127.0.0.1",
		"mode":                "rule",
		"log-level":           "warning",
		"allow-lan":           false,
		"find-process-mode":   "off",
		"profile": map[string]any{
			"store-selected": false,
			"store-fake-ip":  false,
		},
		"dns": map[string]any{
			"enable":         true,
			"ipv6":           false,
			"enhanced-mode":  "fake-ip",
			"fake-ip-range":  "198.18.0.0/15",
			"fake-ip-filter": []string{"*.lan", "*.local", "localhost"},
			"nameserver-policy": map[string]string{
				"+.local":        "rcode://success",
				"+.in-addr.arpa": "rcode://success",
				"+.ip6.arpa":     "rcode://success",
			},
			"default-nameserver":      []string{"https://1.1.1.1/dns-query"},
			"nameserver":              []string{"https://1.1.1.1/dns-query"},
			"proxy-server-nameserver": []string{"https://1.1.1.1/dns-query"},
			"direct-nameserver":       []string{"https://1.1.1.1/dns-query"},
			"respect-rules":           true,
		},
		"sniffer": map[string]any{
			"enable":               true,
			"force-dns-mapping":    false,
			"parse-pure-ip":        true,
			"override-destination": true,
			"sniff": map[string]any{
				"HTTP": map[string]any{
					"ports":                []string{"80", "8080-8880"},
					"override-destination": true,
				},
				"TLS":  map[string]any{"ports": []string{"443", "8443"}},
				"QUIC": map[string]any{"ports": []string{"443", "8443"}},
			},
		},
		"tun": map[string]any{
			"enable":                true,
			"stack":                 "gvisor",
			"auto-route":            false,
			"auto-detect-interface": false,
			"dns-hijack":            []string{"any:53"},
			"mtu":                   9000,
		},
		"proxies": sub.Proxies,
		"proxy-groups": []map[string]any{
			{"name": "PROXY", "type": "select", "proxies": names},
		},
		"rules": []string{
			"IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
			"IP-CIDR,10.0.0.0/8,REJECT,no-resolve",
			"IP-CIDR,100.64.0.0/10,REJECT,no-resolve",
			"IP-CIDR,192.168.0.0/16,REJECT,no-resolve",
			"IP-CIDR,224.0.0.0/4,REJECT,no-resolve",
			"IP-CIDR,fc00::/7,REJECT,no-resolve",
			"IP-CIDR,fe80::/10,REJECT,no-resolve",
			"IP-CIDR,ff00::/8,REJECT,no-resolve",
			"MATCH,PROXY",
		},
	}
	buf, err := json.Marshal(cfg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if _, err := mconfig.Parse(buf); err != nil {
		t.Fatalf("generated config structure failed to parse: %v", err)
	}
}
