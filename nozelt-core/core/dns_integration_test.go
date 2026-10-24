package core

import (
	"context"
	"encoding/json"
	"net"
	"net/netip"
	"sync/atomic"
	"testing"
	"time"

	mdns "github.com/metacubex/mihomo/dns"
	D "github.com/miekg/dns"
)

// Real UDP/TCP DNS packets on ephemeral loopback sockets. No TUN, WFP, system
// resolver, public upstream or host route is touched by these tests.
func localDNS(t *testing.T, handler D.Handler) string {
	return localDNSHandlers(t, handler, handler)
}

func localDNSHandlers(t *testing.T, udpHandler, tcpHandler D.Handler) string {
	t.Helper()
	udp, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	tcp, err := net.Listen("tcp4", udp.LocalAddr().String())
	if err != nil {
		udp.Close()
		t.Fatal(err)
	}
	us := &D.Server{PacketConn: udp, Handler: udpHandler}
	ts := &D.Server{Listener: tcp, Handler: tcpHandler}
	ready := make(chan bool, 2)
	us.NotifyStartedFunc = func() { ready <- true }
	ts.NotifyStartedFunc = func() { ready <- true }
	go us.ActivateAndServe()
	go ts.ActivateAndServe()
	for i := 0; i < 2; i++ {
		select {
		case <-ready:
		case <-time.After(3 * time.Second):
			t.Fatal("local DNS startup timeout")
		}
	}
	t.Cleanup(func() { us.Shutdown(); ts.Shutdown() })
	return udp.LocalAddr().String()
}

func fixtureDNS(t *testing.T, ip string, count *atomic.Int32) string {
	return localDNS(t, D.HandlerFunc(func(w D.ResponseWriter, q *D.Msg) {
		count.Add(1)
		r := new(D.Msg)
		r.SetReply(q)
		if q.Question[0].Qtype == D.TypeA {
			r.Answer = []D.RR{&D.A{Hdr: D.RR_Header{Name: q.Question[0].Name, Rrtype: D.TypeA, Class: D.ClassINET, Ttl: 600}, A: net.ParseIP(ip)}}
		}
		w.WriteMsg(r)
	}))
}

func dnsService(t *testing.T, config map[string]any) (*mdns.Service, *mdns.ResolverEnhancer, *mdns.Resolver) {
	t.Helper()
	value := map[string]any{"dns": config, "ipv6": true, "profile": map[string]any{"store-fake-ip": false}}
	data, _ := json.Marshal(value)
	parsed, err := parseConfig(string(data))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { closeProxyAdapters(parsed.cfg) })
	d := parsed.cfg.DNS
	r := mdns.NewResolver(mdns.Config{Main: d.NameServer, Default: d.DefaultNameserver,
		Fallback: d.Fallback, FallbackIPFilter: d.FallbackIPFilter,
		FallbackDomainFilter: d.FallbackDomainFilter, FallbackLazyQuery: d.FallbackLazyQuery,
		Policy: d.NameServerPolicy, CacheAlgorithm: d.CacheAlgorithm, CacheMaxSize: d.CacheMaxSize, IPv6: d.IPv6})
	e := mdns.NewEnhancer(mdns.EnhancerConfig{IPv6: d.IPv6, EnhancedMode: d.EnhancedMode,
		FakeIPPool: d.FakeIPPool, FakeIPPool6: d.FakeIPPool6, FakeIPSkipper: d.FakeIPSkipper, FakeIPTTL: d.FakeIPTTL, UseHosts: false})
	t.Cleanup(r.ResetConnection)
	return mdns.NewService(r.Resolver, e), e, r.Resolver
}

func queryDNS(t *testing.T, network, addr, name string, qtype uint16) *D.Msg {
	t.Helper()
	q := new(D.Msg)
	q.SetQuestion(D.Fqdn(name), qtype)
	q.SetEdns0(1232, false)
	r, _, err := (&D.Client{Net: network, Timeout: 3 * time.Second}).Exchange(q, addr)
	if err != nil {
		t.Fatal(err)
	}
	if r.Rcode != D.RcodeSuccess || r.Id != q.Id || r.IsEdns0() == nil {
		t.Fatal("invalid DNS response")
	}
	return r
}

func TestFakeDNSOverUDPAndTCP(t *testing.T) {
	for _, mode := range []string{"blacklist", "whitelist", "rule", "redir-host"} {
		t.Run(mode, func(t *testing.T) {
			var count atomic.Int32
			upstream := fixtureDNS(t, "192.0.2.10", &count)
			filterMode, enhanced := mode, "fake-ip"
			filters := []string{"+.real.test"}
			if mode == "whitelist" {
				filters = []string{"+.fake.test"}
			}
			if mode == "rule" {
				filters = []string{"DOMAIN-SUFFIX,real.test,real-ip", "MATCH,fake-ip"}
			}
			if mode == "redir-host" {
				enhanced, filterMode = mode, "blacklist"
			}
			service, enhancer, _ := dnsService(t, map[string]any{
				"enable": true, "enhanced-mode": enhanced, "ipv6": true,
				"fake-ip-range": "198.18.0.0/15", "fake-ip-range6": "fdfe:dcba:9876::/64",
				"fake-ip-filter-mode": filterMode, "fake-ip-filter": filters, "fake-ip-ttl": 37,
				"nameserver": []string{upstream}, "default-nameserver": []string{upstream},
				"cache-algorithm": "arc", "cache-max-size": 64,
			})
			server := &mdns.Server{}
			server.SetService(service)
			addr := localDNSHandlers(t, server.UDPHandler(), server.TCPHandler())
			var previous string
			for _, network := range []string{"udp", "tcp"} {
				r := queryDNS(t, network, addr, "www.fake.test", D.TypeA)
				a := r.Answer[0].(*D.A)
				ip := netip.MustParseAddr(a.A.String())
				if mode == "redir-host" {
					if ip.String() != "192.0.2.10" {
						t.Fatal("redir-host did not return real IP")
					}
				} else {
					if !netip.MustParsePrefix("198.18.0.0/15").Contains(ip) || a.Hdr.Ttl != 37 {
						t.Fatal("wrong Fake-IP or TTL")
					}
				}
				if previous != "" && previous != ip.String() {
					t.Fatal("mapping changed between UDP and TCP")
				}
				previous = ip.String()
				if host, ok := enhancer.FindHostByIP(ip); !ok || host != "www.fake.test" {
					t.Fatal("reverse mapping missing")
				}
				real := queryDNS(t, network, addr, "www.real.test", D.TypeA)
				if real.Answer[0].(*D.A).A.String() != "192.0.2.10" {
					t.Fatal("filter did not return real IP")
				}
			}
			if mode != "redir-host" {
				r := queryDNS(t, "udp", addr, "www.fake.test", D.TypeAAAA)
				ip := netip.MustParseAddr(r.Answer[0].(*D.AAAA).AAAA.String())
				if !netip.MustParsePrefix("fdfe:dcba:9876::/64").Contains(ip) {
					t.Fatal("wrong IPv6 Fake-IP")
				}
			}
			want := int32(1)
			if mode == "redir-host" {
				want = 2
			}
			if count.Load() != want {
				t.Fatalf("cache/upstream queries = %d, want %d", count.Load(), want)
			}
		})
	}
}

func TestDNSPolicyFallbackAndIPv6Off(t *testing.T) {
	var primaryCount, fallbackCount atomic.Int32
	primary := fixtureDNS(t, "192.0.2.10", &primaryCount)
	fallback := fixtureDNS(t, "203.0.113.20", &fallbackCount)
	for _, algo := range []string{"lru", "arc"} {
		t.Run(algo, func(t *testing.T) {
			service, _, resolver := dnsService(t, map[string]any{
				"enable": true, "enhanced-mode": "redir-host", "ipv6": false,
				"nameserver": []string{primary}, "default-nameserver": []string{primary},
				"fallback": []string{fallback}, "fallback-lazy-query": true,
				"fallback-filter":   map[string]any{"geoip": false, "domain": []string{"+.fallback.test"}, "ipcidr": []string{"240.0.0.0/4"}},
				"nameserver-policy": map[string]any{"+.policy.test": []string{fallback}, "+.local": "rcode://success"},
				"cache-algorithm":   algo, "cache-max-size": 32,
			})
			beforeP, beforeF := primaryCount.Load(), fallbackCount.Load()
			for _, entry := range []struct{ name, ip string }{
				{"www.primary.test", "192.0.2.10"}, {"www.fallback.test", "203.0.113.20"}, {"www.policy.test", "203.0.113.20"},
			} {
				q := new(D.Msg)
				q.SetQuestion(entry.name+".", D.TypeA)
				for i := 0; i < 2; i++ {
					r, err := service.ServeMsg(context.Background(), q)
					if err != nil || len(r.Answer) != 1 || r.Answer[0].(*D.A).A.String() != entry.ip {
						t.Fatal("policy/fallback answer mismatch", err)
					}
				}
			}
			for _, entry := range []struct {
				name string
				tp   uint16
			}{{"printer.local.", D.TypeA}, {"www.ipv6.test.", D.TypeAAAA}} {
				q := new(D.Msg)
				q.SetQuestion(entry.name, entry.tp)
				r, err := service.ServeMsg(context.Background(), q)
				if err != nil || len(r.Answer) != 0 {
					t.Fatal("local/IPv6 policy should return empty response")
				}
			}
			if primaryCount.Load()-beforeP != 1 || fallbackCount.Load()-beforeF != 2 {
				t.Fatal("cache or lazy fallback leaked extra queries")
			}
			resolver.ClearCache()
			q := new(D.Msg)
			q.SetQuestion("www.primary.test.", D.TypeA)
			if _, err := service.ServeMsg(context.Background(), q); err != nil {
				t.Fatal(err)
			}
			if primaryCount.Load()-beforeP != 2 {
				t.Fatal("cache clear failed")
			}
		})
	}
}
