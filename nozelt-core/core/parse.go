package core

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"github.com/metacubex/mihomo/common/convert"
	mconfig "github.com/metacubex/mihomo/config"

	"github.com/nozelt/nozelt-core/logger"
	"gopkg.in/yaml.v3"
)

const (
	maxProxyLinkBytes      = 64 * 1024
	maxSubscriptionBytes   = 16 * 1024 * 1024
	maxSubscriptionProxies = 4096
)

// This file delegates proxy-link and subscription parsing to mihomo's
// battle-tested convert package. We do NOT hand-roll parsers on the host
// side: share-link formats vary wildly between panels (Remnawave, Marzban,
// 3x-ui, ...), especially for Reality/XHTTP, and mihomo already normalises
// them into its own proxy maps.
//
// Network I/O (downloading a subscription URL) is deliberately the host's
// job — these functions only parse already-fetched content.

// linkResult is the JSON envelope ParseProxyLink returns across the gomobile
// boundary. Exactly one of Proxy / Error is meaningful, keyed off OK.
type linkResult struct {
	OK            bool           `json:"ok"`
	Proxy         map[string]any `json:"proxy,omitempty"`
	SuggestedCore string         `json:"suggestedCore,omitempty"`
	Error         string         `json:"error,omitempty"`
}

// subResult is the JSON envelope ParseSubscription returns.
type subResult struct {
	OK              bool             `json:"ok"`
	Proxies         []map[string]any `json:"proxies,omitempty"`
	Count           int              `json:"count"`
	ProfileName     string           `json:"profileName,omitempty"`
	Description     string           `json:"description,omitempty"`
	WebPageURL      string           `json:"webPageUrl,omitempty"`
	SuggestedCore   string           `json:"suggestedCore,omitempty"`
	ProviderRouting map[string]any   `json:"providerRouting,omitempty"`
	Error           string           `json:"error,omitempty"`
}

// ParseProxyLink parses a single proxy share link (vless://, vmess://, ss://,
// trojan://, hysteria2://, tuic://, anytls://, ...) into a mihomo proxy map.
// Returns a JSON envelope: {"ok":true,"proxy":{...}} or
// {"ok":false,"error":"..."}. Never panics — convert is wrapped in recover.
func ParseProxyLink(link string) string {
	if len(link) > maxProxyLinkBytes {
		return encodeJSON(linkResult{OK: false, Error: "proxy link exceeds the safe size limit"})
	}
	proxies, err := safeConvert(link)
	if err != nil {
		// Upstream converter errors are not a stable API and may echo parts of
		// the credential-bearing input. Return a deterministic safe message.
		return encodeJSON(linkResult{OK: false, Error: "proxy link is unsupported or malformed"})
	}
	proxies = filterUsableImportedProxies(proxies)
	if len(proxies) == 0 {
		return encodeJSON(linkResult{
			OK:    false,
			Error: "no proxy could be parsed from the link (unsupported scheme or malformed)",
		})
	}
	return encodeJSON(linkResult{
		OK:            true,
		Proxy:         proxies[0],
		SuggestedCore: suggestedCore(proxies),
	})
}

// Preserve only routing data, never provider listeners/DNS/controllers or
// executable hooks. One copy per profile avoids quadratic secret duplication.
func extractProviderRouting(content string, proxies []map[string]any) map[string]any {
	decoded := string(convert.DecodeBase64([]byte(content)))
	if !looksLikeClashConfig(decoded) {
		return nil
	}
	var document map[string]any
	if yaml.Unmarshal([]byte(decoded), &document) != nil {
		return nil
	}
	routing := make(map[string]any)
	for _, key := range []string{"rules", "proxy-groups", "rule-providers", "sub-rules"} {
		if value, exists := document[key]; exists {
			routing[key] = value
		}
	}
	if len(routing) == 0 {
		return nil
	}
	names := make([]string, 0, len(proxies))
	for _, p := range proxies {
		names = append(names, fmt.Sprint(p["name"]))
	}
	routing["node-names"] = names
	return routing
}

// ParseSubscription parses already-downloaded subscription content into a list
// of mihomo proxy maps. It accepts three shapes, in this precedence:
//
//  1. a Clash/mihomo YAML document (detected by a top-level `proxies:` key);
//  2. a base64-encoded list of share links;
//  3. a plain-text list of share links (one per line).
//
// Returns {"ok":true,"proxies":[...],"count":N} or {"ok":false,"error":"..."}.
func ParseSubscription(content string) string {
	if len(content) > maxSubscriptionBytes {
		return encodeJSON(subResult{OK: false, Error: "subscription exceeds the safe size limit"})
	}
	proxies, err := parseSubscriptionContent(content)
	if err != nil {
		return encodeJSON(subResult{OK: false, Error: err.Error()})
	}
	if len(proxies) > maxSubscriptionProxies {
		return encodeJSON(subResult{OK: false, Error: "subscription contains too many proxies"})
	}
	proxies = filterUsableImportedProxies(proxies)
	if len(proxies) == 0 {
		return encodeJSON(subResult{OK: false, Error: "subscription contains no usable remote proxies"})
	}
	name, description, webPageURL := extractSubscriptionMetadata(content, proxies)
	return encodeJSON(subResult{
		OK:              true,
		Proxies:         proxies,
		Count:           len(proxies),
		ProfileName:     name,
		Description:     description,
		WebPageURL:      webPageURL,
		SuggestedCore:   suggestedCore(proxies),
		ProviderRouting: extractProviderRouting(content, proxies),
	})
}

func suggestedCore(proxies []map[string]any) string {
	sawSingBox := false
	for _, proxy := range proxies {
		core := strings.TrimSpace(fmt.Sprint(proxy["nozelt-native-core"]))
		if core == "xray" {
			return core
		}
		sawSingBox = sawSingBox || core == "sing_box"
	}
	if sawSingBox {
		return "sing_box"
	}
	return "mihomo"
}

func extractSubscriptionMetadata(content string, proxies []map[string]any) (
	name, description, webPageURL string,
) {
	decoded := string(convert.DecodeBase64([]byte(content)))
	var document map[string]any
	if err := yaml.Unmarshal([]byte(decoded), &document); err != nil {
		return "", "", ""
	}

	name = firstMetadataString(document, "name", "title", "profile-title")
	description = firstMetadataString(
		document,
		"description",
		"message",
		"announce",
	)
	webPageURL = firstMetadataString(
		document,
		"telegram",
		"homepage",
		"profile-web-page-url",
		"support-url",
	)
	if name == "" {
		name = matchingSelectorName(document["proxy-groups"], proxies)
	}
	return truncateMetadata(name, 96),
		truncateMetadata(description, 4096),
		truncateMetadata(webPageURL, 8192)
}

func firstMetadataString(document map[string]any, keys ...string) string {
	for _, key := range keys {
		value, ok := document[key].(string)
		if value = strings.TrimSpace(value); ok && value != "" {
			return value
		}
	}
	return ""
}

func matchingSelectorName(rawGroups any, proxies []map[string]any) string {
	groups, ok := rawGroups.([]any)
	if !ok {
		return ""
	}
	proxyNames := make(map[string]struct{}, len(proxies))
	for _, proxy := range proxies {
		if value, ok := proxy["name"].(string); ok {
			proxyNames[value] = struct{}{}
		}
	}
	var genericFallback string
	for _, rawGroup := range groups {
		group, ok := rawGroup.(map[string]any)
		if !ok || !strings.EqualFold(strings.TrimSpace(fmt.Sprint(group["type"])), "select") {
			continue
		}
		members, ok := group["proxies"].([]any)
		if !ok {
			continue
		}
		matchesProxy := false
		for _, member := range members {
			if _, exists := proxyNames[fmt.Sprint(member)]; exists {
				matchesProxy = true
				break
			}
		}
		if !matchesProxy {
			continue
		}
		candidate := strings.TrimSpace(fmt.Sprint(group["name"]))
		if candidate == "" || candidate == "<nil>" {
			continue
		}
		switch strings.ToUpper(candidate) {
		case "PROXY", "GLOBAL", "SELECT", "AUTO":
			if genericFallback == "" {
				genericFallback = candidate
			}
		default:
			return candidate
		}
	}
	return genericFallback
}

func truncateMetadata(value string, maxRunes int) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	runes := []rune(value)
	if len(runes) > maxRunes {
		runes = runes[:maxRunes]
	}
	return string(runes)
}

// Clash allows pseudo-outbounds such as DIRECT inside proxy-like structures.
// They are useful in desktop groups but unsafe as Nozelt nodes: mihomo would
// dial them through a VpnService-protected socket and silently send traffic on
// the clear underlay. Keep only real remote proxy adapter types at import.
func filterUsableImportedProxies(proxies []map[string]any) []map[string]any {
	blocked := map[string]struct{}{
		"direct": {}, "reject": {}, "reject-drop": {}, "pass": {},
		"compatible": {}, "dns": {}, "selector": {}, "url-test": {},
		"fallback": {}, "load-balance": {}, "relay": {},
	}
	usable := make([]map[string]any, 0, len(proxies))
	for _, proxy := range proxies {
		if automaticMembers, automatic := proxy["nozelt-auto-members"].([]map[string]any); automatic {
			if len(automaticMembers) < 2 || len(automaticMembers) > 64 {
				continue
			}
			validMembers := true
			for _, member := range automaticMembers {
				if !isUsableRemoteProxy(member, blocked) {
					validMembers = false
					break
				}
			}
			if validMembers {
				usable = append(usable, proxy)
			}
			continue
		}
		if isUsableRemoteProxy(proxy, blocked) {
			usable = append(usable, proxy)
		}
	}
	return usable
}

func isUsableRemoteProxy(proxy map[string]any, blocked map[string]struct{}) bool {
	proxyType, ok := proxy["type"].(string)
	proxyType = strings.TrimSpace(proxyType)
	if !ok || proxyType == "" || len(proxyType) > 64 || hasASCIIControl(proxyType) {
		return false
	}
	if _, denied := blocked[strings.ToLower(proxyType)]; denied {
		return false
	}
	server, ok := proxy["server"].(string)
	server = strings.TrimSpace(server)
	if !ok || server == "" || len(server) > 1024 || hasASCIIControl(server) {
		return false
	}
	port, err := strconv.Atoi(strings.TrimSpace(fmt.Sprint(proxy["port"])))
	if err != nil || port < 1 || port > 65535 {
		return false
	}
	return true
}

func hasASCIIControl(value string) bool {
	return strings.IndexFunc(value, func(r rune) bool { return r < 0x20 || r == 0x7f }) >= 0
}

func parseSubscriptionContent(content string) ([]map[string]any, error) {
	if strings.TrimSpace(content) == "" {
		return nil, fmt.Errorf("subscription content is empty")
	}

	// DecodeBase64 is a no-op passthrough when the content is not base64, so
	// this yields the plaintext form whether the panel served base64 or not.
	decoded := string(convert.DecodeBase64([]byte(content)))

	// A complete sing-box document must stay intact: selector/urltest
	// outbounds and route rules cannot be faithfully flattened into Clash
	// share links. Keep it encrypted in the node metadata and run it on the
	// native sing-box process.
	if proxies := parseSingBoxJSONConfigs(decoded); len(proxies) > 0 {
		return proxies, nil
	}

	// Happ subscriptions may contain complete Xray JSON server entries. A
	// leastLoad/burstObservatory entry is translated into one app-owned
	// automatic node whose members are ordinary mihomo VLESS proxies.
	if proxies := parseHappJSONConfigs(decoded); len(proxies) > 0 {
		return proxies, nil
	}

	// 1. Clash/mihomo YAML. Checked first so a stray `https://` inside a YAML
	//    (e.g. external-ui) is not mistaken for an http proxy by the link
	//    parser.
	if looksLikeClashConfig(decoded) {
		if proxies, err := parseClashProxies([]byte(decoded)); err == nil && len(proxies) > 0 {
			return proxies, nil
		}
	}

	// 2 & 3. V2Ray link list (convert handles base64 vs plaintext itself).
	proxies, err := safeConvert(content)
	if err == nil && len(proxies) > 0 {
		return proxies, nil
	}

	// Last resort: try YAML even if the heuristic missed (e.g. no `proxies:`
	// line but still a valid config fragment).
	if yamlProxies, yerr := parseClashProxies([]byte(decoded)); yerr == nil && len(yamlProxies) > 0 {
		return yamlProxies, nil
	}

	if err != nil {
		return nil, fmt.Errorf("could not parse subscription")
	}
	return nil, fmt.Errorf("subscription contains no recognisable proxies")
}

func parseSingBoxJSONConfigs(content string) []map[string]any {
	var raw any
	if json.Unmarshal([]byte(strings.TrimSpace(content)), &raw) != nil {
		return nil
	}
	documents := xrayDocumentsFromJSON(raw)
	result := make([]map[string]any, 0, len(documents))
	for _, document := range documents {
		proxy := convertSingBoxDocument(document)
		if proxy != nil {
			result = append(result, proxy)
		}
	}
	return result
}

func convertSingBoxDocument(document map[string]any) map[string]any {
	rawOutbounds, ok := document["outbounds"].([]any)
	if !ok {
		return nil
	}
	for _, rawOutbound := range rawOutbounds {
		outbound, ok := rawOutbound.(map[string]any)
		if !ok || outbound["protocol"] != nil {
			continue
		}
		proxyType := strings.ToLower(strings.TrimSpace(fmt.Sprint(outbound["type"])))
		switch proxyType {
		case "", "<nil>", "direct", "block", "dns", "selector", "urltest":
			continue
		}
		server := strings.TrimSpace(fmt.Sprint(outbound["server"]))
		port, err := strconv.Atoi(strings.TrimSpace(fmt.Sprint(outbound["server_port"])))
		if server == "" || server == "<nil>" || err != nil || port < 1 || port > 65535 {
			continue
		}
		name := strings.TrimSpace(fmt.Sprint(outbound["tag"]))
		if name == "" || name == "<nil>" {
			name = "sing-box proxy"
		}
		return map[string]any{
			"name":                 name,
			"type":                 proxyType,
			"server":               server,
			"port":                 port,
			"nozelt-native-core":   "sing_box",
			"nozelt-native-config": document,
		}
	}
	return nil
}

func parseHappJSONConfigs(content string) []map[string]any {
	documents := decodeXrayJSONDocuments(content)
	result := make([]map[string]any, 0, len(documents))
	for _, document := range documents {
		result = append(result, convertXrayDocument(document)...)
	}
	return result
}

func decodeXrayJSONDocuments(content string) []map[string]any {
	var raw any
	if err := json.Unmarshal([]byte(strings.TrimSpace(content)), &raw); err == nil {
		return xrayDocumentsFromJSON(raw)
	}
	// Some panels return a base64/plain line list where individual entries are
	// complete Xray JSON documents rather than share links. Decode each entry
	// independently; decoding only the complete subscription loses these
	// mixed-format auto-selector records.
	var documents []map[string]any
	for _, line := range strings.Split(content, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		decoded := strings.TrimSpace(string(convert.DecodeBase64([]byte(line))))
		var entry any
		if json.Unmarshal([]byte(decoded), &entry) != nil {
			continue
		}
		documents = append(documents, xrayDocumentsFromJSON(entry)...)
	}
	return documents
}

func xrayDocumentsFromJSON(raw any) []map[string]any {
	var documents []map[string]any
	switch value := raw.(type) {
	case map[string]any:
		documents = append(documents, value)
	case []any:
		for _, entry := range value {
			if document, ok := entry.(map[string]any); ok {
				documents = append(documents, document)
				continue
			}
			if encoded, ok := entry.(string); ok {
				var document map[string]any
				if json.Unmarshal([]byte(encoded), &document) == nil {
					documents = append(documents, document)
				}
			}
		}
	}
	return documents
}

func convertXrayDocument(document map[string]any) []map[string]any {
	rawOutbounds, ok := document["outbounds"].([]any)
	if !ok {
		return nil
	}
	remarks := strings.TrimSpace(fmt.Sprint(document["remarks"]))
	if remarks == "" || remarks == "<nil>" {
		if metadata, ok := document["meta"].(map[string]any); ok {
			remarks = firstNonEmptyString(metadata["serverDescription"])
		}
		if remarks == "" {
			remarks = "Automatic proxy"
		}
	}
	members := make([]map[string]any, 0, len(rawOutbounds))
	for index, rawOutbound := range rawOutbounds {
		outbound, ok := rawOutbound.(map[string]any)
		if !ok {
			continue
		}
		if proxy := convertXrayVlessOutbound(outbound, remarks, index+1); proxy != nil {
			members = append(members, proxy)
		}
	}
	if len(members) == 0 {
		return nil
	}
	testURL, intervalSeconds := xrayDelayTestOptions(document)
	if len(members) == 1 || !hasXrayBalancer(document) {
		members[0]["name"] = remarks
		members[0]["nozelt-native-core"] = "xray"
		members[0]["nozelt-native-config"] = document
		members[0]["nozelt-auto-url"] = testURL
		members[0]["nozelt-auto-interval"] = intervalSeconds
		return members[:1]
	}

	return []map[string]any{{
		"name":                 remarks,
		"type":                 "url-test",
		"server":               members[0]["server"],
		"port":                 members[0]["port"],
		"nozelt-auto-members":  members,
		"nozelt-auto-url":      testURL,
		"nozelt-auto-interval": intervalSeconds,
		"nozelt-native-core":   "xray",
		"nozelt-native-config": document,
	}}
}

func xrayDelayTestOptions(document map[string]any) (testURL string, intervalSeconds int) {
	testURL = "http://www.gstatic.com/generate_204"
	intervalSeconds = 20
	if observatory, ok := document["burstObservatory"].(map[string]any); ok {
		if ping, ok := observatory["pingConfig"].(map[string]any); ok {
			if candidate := strings.TrimSpace(fmt.Sprint(ping["destination"])); strings.HasPrefix(candidate, "http://") ||
				strings.HasPrefix(candidate, "https://") {
				testURL = candidate
			}
			if parsed := parseXrayDurationSeconds(fmt.Sprint(ping["interval"])); parsed >= 10 {
				intervalSeconds = parsed
			}
		}
	}
	return testURL, intervalSeconds
}

func hasXrayBalancer(document map[string]any) bool {
	routing, ok := document["routing"].(map[string]any)
	if !ok {
		return false
	}
	balancers, ok := routing["balancers"].([]any)
	return ok && len(balancers) > 0
}

func parseXrayDurationSeconds(value string) int {
	value = strings.TrimSpace(value)
	if len(value) < 2 {
		return 0
	}
	unit := value[len(value)-1]
	number, err := strconv.Atoi(value[:len(value)-1])
	if err != nil || number < 1 {
		return 0
	}
	switch unit {
	case 's':
		return number
	case 'm':
		return number * 60
	case 'h':
		return number * 3600
	default:
		return 0
	}
}

func convertXrayVlessOutbound(
	outbound map[string]any,
	remarks string,
	index int,
) map[string]any {
	protocol := strings.ToLower(strings.TrimSpace(fmt.Sprint(outbound["protocol"])))
	if protocol != "vless" && protocol != "vmess" {
		return convertGenericXrayServerOutbound(outbound, remarks, index, protocol)
	}
	settings, ok := outbound["settings"].(map[string]any)
	if !ok {
		return nil
	}
	vnext, ok := settings["vnext"].([]any)
	if !ok || len(vnext) == 0 {
		return nil
	}
	target, ok := vnext[0].(map[string]any)
	if !ok {
		return nil
	}
	users, ok := target["users"].([]any)
	if !ok || len(users) == 0 {
		return nil
	}
	user, ok := users[0].(map[string]any)
	if !ok {
		return nil
	}
	server := strings.TrimSpace(fmt.Sprint(target["address"]))
	port, err := strconv.Atoi(strings.TrimSpace(fmt.Sprint(target["port"])))
	uuid := strings.TrimSpace(fmt.Sprint(user["id"]))
	if server == "" || uuid == "" || err != nil || port < 1 || port > 65535 {
		return nil
	}
	name := fmt.Sprintf("%s / %d", remarks, index)
	if tag := strings.TrimSpace(fmt.Sprint(outbound["tag"])); tag != "" && tag != "<nil>" {
		name = fmt.Sprintf("%s / %s", remarks, tag)
	}
	proxy := map[string]any{
		"name":       name,
		"type":       protocol,
		"server":     server,
		"port":       port,
		"uuid":       uuid,
		"encryption": "none",
	}
	if protocol == "vmess" {
		delete(proxy, "encryption")
		proxy["cipher"] = firstNonEmptyString(user["security"], "auto")
		if alterID, err := strconv.Atoi(strings.TrimSpace(fmt.Sprint(user["alterId"]))); err == nil {
			proxy["alterId"] = alterID
		}
	}
	if flow := strings.TrimSpace(fmt.Sprint(user["flow"])); flow != "" && flow != "<nil>" {
		proxy["flow"] = flow
	}
	stream, _ := outbound["streamSettings"].(map[string]any)
	network := strings.ToLower(strings.TrimSpace(fmt.Sprint(stream["network"])))
	if network == "" || network == "<nil>" {
		network = "tcp"
	}
	proxy["network"] = network
	security := strings.ToLower(strings.TrimSpace(fmt.Sprint(stream["security"])))
	if security == "tls" {
		proxy["tls"] = true
		if tls, ok := stream["tlsSettings"].(map[string]any); ok {
			if sni := strings.TrimSpace(fmt.Sprint(tls["serverName"])); sni != "" && sni != "<nil>" {
				proxy["servername"] = sni
			}
			if fingerprint := strings.TrimSpace(fmt.Sprint(tls["fingerprint"])); fingerprint != "" && fingerprint != "<nil>" {
				proxy["client-fingerprint"] = fingerprint
			}
		}
	}
	if network == "grpc" {
		if grpc, ok := stream["grpcSettings"].(map[string]any); ok {
			opts := map[string]any{}
			if service := strings.TrimSpace(fmt.Sprint(grpc["serviceName"])); service != "" && service != "<nil>" {
				opts["grpc-service-name"] = service
			}
			if authority := strings.TrimSpace(fmt.Sprint(grpc["authority"])); authority != "" && authority != "<nil>" {
				opts["grpc-authority"] = authority
			}
			if len(opts) > 0 {
				proxy["grpc-opts"] = opts
			}
		}
	}
	return proxy
}

func convertGenericXrayServerOutbound(
	outbound map[string]any,
	remarks string,
	index int,
	protocol string,
) map[string]any {
	switch protocol {
	case "trojan", "shadowsocks", "hysteria", "hysteria2":
	default:
		return nil
	}
	settings, ok := outbound["settings"].(map[string]any)
	if !ok {
		return nil
	}
	// Happ's Xray Hysteria extension stores address/port/version directly in
	// outbound.settings, while Trojan/Shadowsocks and some older Hysteria
	// documents use settings.servers[0]. Accept both shapes. The complete
	// provider document remains authoritative and is preserved by the caller.
	serverOptions := settings
	if servers, hasServers := settings["servers"].([]any); hasServers {
		if len(servers) == 0 {
			return nil
		}
		var serverOK bool
		serverOptions, serverOK = servers[0].(map[string]any)
		if !serverOK {
			return nil
		}
	}
	server := firstNonEmptyString(serverOptions["address"], serverOptions["server"])
	port, err := strconv.Atoi(strings.TrimSpace(fmt.Sprint(serverOptions["port"])))
	if server == "" || err != nil || port < 1 || port > 65535 {
		return nil
	}
	name := fmt.Sprintf("%s / %d", remarks, index)
	if tag := strings.TrimSpace(fmt.Sprint(outbound["tag"])); tag != "" && tag != "<nil>" {
		name = fmt.Sprintf("%s / %s", remarks, tag)
	}
	proxyType := protocol
	if protocol == "hysteria" {
		proxyType = "hysteria2"
	}
	proxy := map[string]any{
		"name":   name,
		"type":   proxyType,
		"server": server,
		"port":   port,
	}
	for _, key := range []string{"password", "method", "cipher"} {
		if value := firstNonEmptyString(serverOptions[key]); value != "" {
			targetKey := key
			if key == "method" {
				targetKey = "cipher"
			}
			proxy[targetKey] = value
		}
	}
	if protocol == "hysteria" || protocol == "hysteria2" {
		if stream, ok := outbound["streamSettings"].(map[string]any); ok {
			if hysteria, ok := stream["hysteriaSettings"].(map[string]any); ok {
				if auth := firstNonEmptyString(hysteria["auth"]); auth != "" {
					proxy["password"] = auth
				}
			}
			if tls, ok := stream["tlsSettings"].(map[string]any); ok {
				if sni := firstNonEmptyString(tls["serverName"]); sni != "" {
					proxy["sni"] = sni
				}
				if insecure, ok := tls["allowInsecure"].(bool); ok {
					proxy["skip-cert-verify"] = insecure
				}
			}
		}
	}
	return proxy
}

func firstNonEmptyString(values ...any) string {
	for _, value := range values {
		candidate := strings.TrimSpace(fmt.Sprint(value))
		if candidate != "" && candidate != "<nil>" {
			return candidate
		}
	}
	return ""
}

// looksLikeClashConfig reports whether s is (very likely) a Clash/mihomo YAML
// document rather than a share-link list, by looking for the top-level
// `proxies:` / `proxy-providers:` key.
func looksLikeClashConfig(s string) bool {
	for _, line := range strings.Split(s, "\n") {
		t := strings.TrimSpace(line)
		if strings.HasPrefix(t, "proxies:") || strings.HasPrefix(t, "proxy-providers:") {
			return true
		}
	}
	return false
}

// parseClashProxies extracts the `proxies` array from a Clash/mihomo YAML doc
// using mihomo's own raw-config unmarshaller. Wrapped in recover for safety.
func parseClashProxies(buf []byte) (proxies []map[string]any, err error) {
	defer func() {
		if recover() != nil {
			proxies = nil
			err = fmt.Errorf("malformed clash yaml")
			logger.Warn("nozelt core: recovered from malformed clash input")
		}
	}()
	raw, err := mconfig.UnmarshalRawConfig(buf)
	if err != nil {
		return nil, err
	}
	return raw.Proxy, nil
}

// safeConvert wraps convert.ConvertsV2Ray with a recover so malformed input
// that trips a panic inside mihomo becomes an ordinary error instead of
// crashing the whole app process across the JNI boundary.
func safeConvert(content string) (proxies []map[string]any, err error) {
	defer func() {
		if r := recover(); r != nil {
			proxies = nil
			err = fmt.Errorf("malformed proxy link/subscription")
			// A panic payload from a third-party parser can include the original
			// share link. Never forward it across the logger boundary.
			logger.Warn("nozelt core: recovered from malformed proxy input")
		}
	}()
	proxies, err = convert.ConvertsV2Ray([]byte(content))
	if err == nil {
		normalizeConvertedProxies(proxies)
	}
	return proxies, err
}

// normalizeConvertedProxies applies protocol defaults that are defined by the
// share-link format but omitted by some providers. Xeovo and other SIP002
// subscriptions commonly encode `v2ray-plugin;tls;host=...;path=...` without
// an explicit `mode`: v2ray-plugin's transport is WebSocket by default. The
// upstream mihomo converter currently leaves that mode empty, and mihomo then
// rejects the complete configuration before any node can start.
func normalizeConvertedProxies(proxies []map[string]any) {
	for _, proxy := range proxies {
		if !strings.EqualFold(strings.TrimSpace(fmt.Sprint(proxy["type"])), "ss") ||
			!strings.EqualFold(strings.TrimSpace(fmt.Sprint(proxy["plugin"])), "v2ray-plugin") {
			continue
		}
		options, ok := proxy["plugin-opts"].(map[string]any)
		if !ok {
			continue
		}
		mode := strings.TrimSpace(fmt.Sprint(options["mode"]))
		if mode == "" || mode == "<nil>" {
			options["mode"] = "websocket"
		}
	}
}

func encodeJSON(v any) string {
	out, err := json.Marshal(v)
	if err != nil {
		return `{"ok":false,"error":"failed to encode parse result"}`
	}
	return string(out)
}
