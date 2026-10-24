//go:build windows

package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"strconv"
	"testing"
	"time"

	"golang.org/x/net/proxy"
)

// Explicit opt-in: uses a selected profile to contact a public HTTPS endpoint,
// without installing a TUN, changing routes or stopping another VPN.
func TestRelaySelectedProfileHTTPS(t *testing.T) {
	path := os.Getenv("NOZELT_RELAY_PROBE_DPAPI")
	if path == "" {
		t.Skip("selected-profile diagnostic not supplied")
	}
	encoded, err := os.ReadFile(path)
	if err != nil {
		t.Fatal("encrypted diagnostic unavailable")
	}
	protected, err := base64.StdEncoding.DecodeString(string(encoded))
	if err != nil {
		t.Fatal("invalid encrypted diagnostic")
	}
	data, err := unprotectData(protected)
	if err != nil {
		t.Fatal("diagnostic could not be decrypted")
	}
	var document struct {
		Core   string          `json:"core"`
		Config json.RawMessage `json:"config"`
	}
	if json.Unmarshal(data, &document) != nil {
		t.Fatal("invalid diagnostic document")
	}
	if document.Core != runtimeXray && document.Core != runtimeSingBox {
		t.Fatal("unsupported diagnostic core")
	}
	var envelope relayConfig
	if json.Unmarshal(document.Config, &envelope) != nil {
		t.Fatal("invalid diagnostic relay")
	}
	probeConfig, _ := json.Marshal(envelope.Transport)
	targets, _ := json.Marshal([]externalDelayTarget{{
		Name: "selected-diagnostic", Config: string(probeConfig),
		URL: "https://www.gstatic.com/generate_204",
	}})
	var delays externalDelayEnvelope
	if json.Unmarshal([]byte(testExternalProxyDelays(document.Core, string(targets), 5000)), &delays) != nil ||
		!delays.OK || delays.Results["selected-diagnostic"].Delay <= 0 {
		t.Fatal("selected-profile native latency probe failed")
	}
	t.Logf("native latency probe: %d ms", delays.Results["selected-diagnostic"].Delay)
	for cycle := 0; cycle < 3; cycle++ {
		relay, err := decodeRelay(string(document.Config))
		if err != nil {
			t.Fatal("transport configuration unavailable")
		}
		r := &windowsRuntime{kind: document.Core, relay: relay}
		if err = r.startRelayChildLocked(); err != nil {
			t.Fatal("transport did not start")
		}
		func() {
			defer r.stopChildLocked()
			dialer, err := proxy.SOCKS5("tcp", "127.0.0.1:"+strconv.Itoa(relay.port),
				&proxy.Auth{User: "nozelt", Password: relay.password}, proxy.Direct)
			if err != nil {
				t.Fatal("SOCKS diagnostic unavailable")
			}
			transport := &http.Transport{DialContext: dialer.(proxy.ContextDialer).DialContext}
			defer transport.CloseIdleConnections()
			client := &http.Client{Transport: transport, Timeout: 20 * time.Second}
			for request := 0; request < 3; request++ {
				ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
				req, _ := http.NewRequestWithContext(ctx, "GET", "https://www.gstatic.com/generate_204", nil)
				started := time.Now()
				response, err := client.Do(req)
				if err != nil {
					cancel()
					t.Fatal("HTTPS through selected transport failed (details withheld)")
				}
				io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
				response.Body.Close()
				cancel()
				if response.StatusCode != 204 {
					t.Fatal("unexpected connectivity response")
				}
				t.Logf("%s cycle %d request %d: HTTPS 204, %d ms, underlay %s", document.Core, cycle+1, request+1, time.Since(started).Milliseconds(), relay.underlay)
			}
		}()
	}
}
