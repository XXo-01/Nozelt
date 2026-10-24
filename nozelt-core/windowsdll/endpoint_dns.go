//go:build windows

package main

import (
	"encoding/json"
	"errors"
	"net"
	"net/url"
	"sort"
	"strconv"

	"github.com/nozelt/nozelt-core/core"
)

// xrayEndpointHosts finds every server name an Xray outbound dials: the
// classic vnext/servers lists, the flat `settings.address` form used by
// newer VLESS/Hysteria documents, WireGuard endpoints and XHTTP download
// servers nested in streamSettings.
func xrayEndpointHosts(outbound map[string]any) []string {
	var hosts []string
	var walk func(value any)
	walk = func(value any) {
		switch typed := value.(type) {
		case map[string]any:
			for key, child := range typed {
				text, isText := child.(string)
				switch {
				case isText && key == "address":
					hosts = append(hosts, text)
				case isText && key == "endpoint":
					if u, err := url.Parse("udp://" + text); err == nil {
						hosts = append(hosts, u.Hostname())
					}
				default:
					walk(child)
				}
			}
		case []any:
			for _, child := range typed {
				walk(child)
			}
		}
	}
	walk(outbound["settings"])
	walk(outbound["streamSettings"])
	return hosts
}

func (relay *relayConfig) applyEndpointDNSPolicies(kind string, document map[string]any) error {
	dns, _ := relay.Frontend["dns"].(map[string]any)
	policies, _ := dns["proxy-server-nameserver-policy"].(map[string]any)
	if len(policies) == 0 {
		return nil
	}
	hosts := map[string]bool{}
	add := func(raw any) {
		if s, ok := raw.(string); ok && s != "" && net.ParseIP(s) == nil {
			hosts[s] = true
		}
	}
	outbounds, _ := document["outbounds"].([]any)
	for _, item := range outbounds {
		outbound, _ := item.(map[string]any)
		if kind == runtimeSingBox {
			add(outbound["server"])
			continue
		}
		for _, host := range xrayEndpointHosts(outbound) {
			add(host)
		}
	}
	list := make([]string, 0, len(hosts))
	for host := range hosts {
		list = append(list, host)
	}
	sort.Strings(list)
	encoded, _ := json.Marshal(relay.Frontend)
	overrides, err := core.EndpointDNSPolicies(string(encoded), list)
	if err != nil {
		return err
	}
	childDNS, ok := document["dns"].(map[string]any)
	if !ok {
		return errors.New("native endpoint DNS unavailable")
	}
	servers, _ := childDNS["servers"].([]any)
	if kind == runtimeXray {
		var result []any
		for _, host := range list {
			for _, endpoint := range overrides[host] {
				u, err := url.Parse(endpoint)
				if err != nil || u.Scheme != "https" {
					return errors.New("Xray endpoint DNS policy requires HTTPS")
				}
				result = append(result, map[string]any{"address": endpoint, "domains": []any{"full:" + host}, "skipFallback": true, "tag": "nozelt-endpoint-dns"})
			}
		}
		for _, entry := range servers {
			if server, ok := entry.(map[string]any); ok && server["tag"] == "nozelt-endpoint-dns" {
				domains, _ := server["domains"].([]any)
				var kept []any
				for _, domain := range domains {
					text, _ := domain.(string)
					if len(text) < 5 || len(overrides[text[5:]]) == 0 {
						kept = append(kept, domain)
					}
				}
				if len(kept) == 0 {
					continue
				}
				server["domains"] = kept
			}
			result = append(result, entry)
		}
		childDNS["servers"] = result
		return nil
	}
	for i, host := range list {
		if len(overrides[host]) == 0 {
			continue
		}
		// Native endpoint bootstrap follows sing-box's single resolver contract;
		// destination DNS redundancy remains in the shared Mihomo frontend.
		u, err := url.Parse(overrides[host][0])
		if err != nil {
			return err
		}
		tag := "endpoint-policy-" + strconv.Itoa(i)
		server := map[string]any{"type": u.Scheme, "tag": tag, "server": u.Hostname(), "tls": map[string]any{"enabled": true, "server_name": u.Hostname()}}
		if u.Port() != "" {
			port, err := strconv.Atoi(u.Port())
			if err != nil {
				return err
			}
			server["server_port"] = port
		}
		if u.Scheme == "https" {
			server["path"] = u.Path
		}
		servers = append(servers, server)
		for _, entry := range outbounds {
			outbound, _ := entry.(map[string]any)
			if outbound["server"] == host {
				outbound["domain_resolver"] = tag
			}
		}
	}
	childDNS["servers"] = servers
	return nil
}
