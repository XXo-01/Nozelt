package core

import (
	"errors"
	"strings"

	"github.com/metacubex/mihomo/component/trie"
	mdns "github.com/metacubex/mihomo/dns"
)

// EndpointDNSPolicies applies the frontend's parsed domain/GeoSite policy to
// native transport endpoint names too. It only parses/matches; no DNS lookup,
// socket, TUN or system change occurs. This prevents a UI setting being honored
// by Mihomo but silently ignored by Xray/sing-box bootstrap.
func EndpointDNSPolicies(config string, hosts []string) (map[string][]string, error) {
	current.mu.Lock()
	defer current.mu.Unlock()
	parsed, err := parseConfig(config)
	if err != nil {
		return nil, err
	}
	defer closeProxyAdapters(parsed.cfg)
	result := make(map[string][]string)
	for _, host := range hosts {
		var selected []mdns.NameServer
		var domains *trie.DomainTrie[[]mdns.NameServer]
		search := func() bool {
			if domains == nil {
				return false
			}
			if item := domains.Search(host); item != nil {
				selected = item.Data()
				return true
			}
			domains = nil
			return false
		}
		for _, policy := range parsed.cfg.DNS.ProxyServerPolicy {
			if policy.Matcher != nil {
				if search() {
					break
				}
				if policy.Matcher.MatchDomain(host) {
					selected = policy.NameServers
					break
				}
			} else {
				if domains == nil {
					domains = trie.New[[]mdns.NameServer]()
				}
				if err := domains.Insert(policy.Domain, policy.NameServers); err != nil {
					return nil, errors.New("invalid endpoint DNS policy")
				}
			}
		}
		if len(selected) == 0 {
			search()
		}
		for _, server := range selected {
			var endpoint string
			switch server.Net {
			case "https":
				endpoint = server.Addr
			case "tls":
				endpoint = "tls://" + server.Addr
			case "quic":
				endpoint = "quic://" + server.Addr
			default:
				return nil, errors.New("encrypted endpoint DNS required")
			}
			result[host] = append(result[host], strings.TrimSpace(endpoint))
		}
	}
	return result, nil
}
