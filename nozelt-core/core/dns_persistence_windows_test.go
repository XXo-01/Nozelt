//go:build windows

package core

import (
	"encoding/json"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/metacubex/mihomo/component/profile/cachefile"
	C "github.com/metacubex/mihomo/constant"
)

func TestWindowsFakeIPPersistence(t *testing.T) {
	directory := t.TempDir()
	for _, stage := range []string{"write", "restore", "off"} {
		cmd := exec.Command(os.Args[0], "-test.run=^TestFakeIPDiskWorker$", "-test.timeout=15s")
		cmd.Env = append(os.Environ(), "NOZELT_DNS_CACHE_TEST_DIR="+directory, "NOZELT_DNS_CACHE_TEST_STAGE="+stage)
		if output, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%s: %v\n%s", stage, err, output)
		}
	}
}

// A separate process for each stage avoids Mihomo's process-global cachefile
// singleton and proves real persistence. Only a temporary test directory and
// synthetic domains are used. Parsing never creates a TUN or DNS listener.
func TestFakeIPDiskWorker(t *testing.T) {
	directory, stage := os.Getenv("NOZELT_DNS_CACHE_TEST_DIR"), os.Getenv("NOZELT_DNS_CACHE_TEST_STAGE")
	if directory == "" {
		t.Skip("child-process fixture only")
	}
	C.SetHomeDir(directory)
	data, _ := json.Marshal(map[string]any{
		"profile": map[string]any{"store-fake-ip": stage != "off"},
		"tun":     map[string]any{"enable": true, "auto-route": true},
		"dns": map[string]any{"enable": true, "ipv6": true, "enhanced-mode": "fake-ip",
			"fake-ip-range": "198.18.0.0/15", "fake-ip-range6": "fdfe:dcba:9876::/64",
			"nameserver": []string{"https://1.1.1.1/dns-query"}},
	})
	parsed, err := parseConfig(string(data))
	if err != nil {
		t.Fatal(err)
	}
	defer closeProxyAdapters(parsed.cfg)
	path := filepath.Join(directory, "expected.json")
	if stage == "write" {
		values := []string{parsed.cfg.DNS.FakeIPPool.Lookup("cache.fixture.test").String(), parsed.cfg.DNS.FakeIPPool6.Lookup("cache6.fixture.test").String()}
		parsed.cfg.DNS.FakeIPPool.StoreState()
		parsed.cfg.DNS.FakeIPPool6.StoreState()
		encoded, _ := json.Marshal(values)
		if err := os.WriteFile(path, encoded, 0600); err != nil {
			t.Fatal(err)
		}
		if err := cachefile.Cache().Close(); err != nil {
			t.Fatal(err)
		}
		return
	}
	encoded, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var expected []string
	json.Unmarshal(encoded, &expected)
	if stage == "off" {
		if parsed.cfg.Profile.StoreFakeIP {
			t.Fatal("opt-out was ignored")
		}
		if _, ok := parsed.cfg.DNS.FakeIPPool.LookBack(netip.MustParseAddr(expected[0])); ok {
			t.Fatal("opt-out read previous disk mappings")
		}
		return
	}
	if !parsed.cfg.Profile.StoreFakeIP {
		t.Fatal("Windows opt-in was ignored")
	}
	if host, ok := parsed.cfg.DNS.FakeIPPool.LookBack(netip.MustParseAddr(expected[0])); !ok || host != "cache.fixture.test" {
		t.Fatal("IPv4 cache did not survive process restart")
	}
	if host, ok := parsed.cfg.DNS.FakeIPPool6.LookBack(netip.MustParseAddr(expected[1])); !ok || host != "cache6.fixture.test" {
		t.Fatal("IPv6 cache did not survive process restart")
	}
	if err := cachefile.Cache().Close(); err != nil {
		t.Fatal(err)
	}
}
