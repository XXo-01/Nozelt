//go:build windows

package networkguard

import (
	"github.com/tailscale/wf"
	"net/netip"
	"testing"
)

func TestPrivateUDPRelayCannotBypassProcessRules(t *testing.T) {
	rules := policy([]string{"nozelt", "xray"}, 42, false, "svchost", 54321)
	for _, protocol := range []uint8{6, 17} {
		for _, app := range []string{"browser", "nozelt", "xray"} {
			values := map[wf.FieldID]any{wf.FieldFlags: wf.ConditionFlagIsLoopback, wf.FieldIPRemoteAddress: netip.MustParseAddr("127.0.0.1"), wf.FieldIPRemotePort: uint16(54321), wf.FieldIPProtocol: protocol, wf.FieldALEAppID: app}
			permit := decision(rules, wf.LayerALEAuthConnectV4, values) == wf.ActionPermit
			if permit != (app != "browser") {
				t.Fatal("private relay ownership violated")
			}
		}
	}
}

// This is a policy decision test, not a call to WFP. It never changes host
// networking. Separate VM tests must verify Windows' actual classifications.
func decision(rules []*wf.Rule, layer wf.LayerID, values map[wf.FieldID]any) wf.Action {
	action, weight := wf.ActionBlock, uint64(0)
	for _, r := range rules {
		if r.Layer != layer {
			continue
		}
		matched := true
		for _, c := range r.Conditions {
			if c.Op == wf.MatchTypeFlagsAllSet || c.Op == wf.MatchTypeFlagsNoneSet {
				actual, _ := values[c.Field].(wf.ConditionFlag)
				flag := c.Value.(wf.ConditionFlag)
				if c.Op == wf.MatchTypeFlagsAllSet {
					matched = matched && actual&flag == flag
				} else {
					matched = matched && actual&flag == 0
				}
			} else if c.Op == wf.MatchTypeNotEqual {
				matched = matched && values[c.Field] != c.Value
			} else {
				matched = matched && values[c.Field] == c.Value
			}
		}
		if matched && r.Weight > weight {
			action, weight = r.Action, r.Weight
		}
	}
	return action
}

func TestFailClosedPolicy(t *testing.T) {
	rules := policy([]string{"nozelt", "xray"}, 42, false, "svchost", 0)
	for _, layer := range []wf.LayerID{wf.LayerALEAuthConnectV4, wf.LayerALEAuthRecvAcceptV4, wf.LayerALEAuthConnectV6, wf.LayerALEAuthRecvAcceptV6} {
		v6 := layer == wf.LayerALEAuthConnectV6 || layer == wf.LayerALEAuthRecvAcceptV6
		cases := []struct {
			name   string
			values map[wf.FieldID]any
			permit bool
		}{
			{"ordinary physical", map[wf.FieldID]any{wf.FieldALEAppID: "browser", wf.FieldIPLocalInterface: uint64(7)}, false},
			{"TUN", map[wf.FieldID]any{wf.FieldALEAppID: "browser", wf.FieldIPLocalInterface: uint64(42)}, !v6},
			{"transport", map[wf.FieldID]any{wf.FieldALEAppID: "xray", wf.FieldIPLocalInterface: uint64(7)}, !v6},
			{"transport plaintext DNS forbidden", map[wf.FieldID]any{wf.FieldALEAppID: "xray", wf.FieldIPLocalInterface: uint64(7), wf.FieldIPProtocol: uint8(17), wf.FieldIPRemotePort: uint16(53)}, false},
			{"host plaintext DNS forbidden", map[wf.FieldID]any{wf.FieldALEAppID: "nozelt", wf.FieldIPLocalInterface: uint64(7), wf.FieldIPProtocol: uint8(6), wf.FieldIPRemotePort: uint16(53)}, false},
			{"TUN DNS intercepted", map[wf.FieldID]any{wf.FieldALEAppID: "svchost", wf.FieldIPLocalInterface: uint64(42), wf.FieldIPProtocol: uint8(17), wf.FieldIPRemotePort: uint16(53)}, !v6},
			{"loopback", map[wf.FieldID]any{wf.FieldFlags: wf.ConditionFlagIsLoopback}, true},
			{"system DNS", map[wf.FieldID]any{wf.FieldALEAppID: "svchost", wf.FieldIPProtocol: uint8(17), wf.FieldIPLocalPort: uint16(52000), wf.FieldIPRemotePort: uint16(53)}, false},
			{"DHCP", map[wf.FieldID]any{wf.FieldALEAppID: "svchost", wf.FieldIPProtocol: uint8(17), wf.FieldIPLocalPort: uint16(68), wf.FieldIPRemotePort: uint16(67)}, !v6},
			{"fake DHCP app", map[wf.FieldID]any{wf.FieldALEAppID: "browser", wf.FieldIPProtocol: uint8(17), wf.FieldIPLocalPort: uint16(68), wf.FieldIPRemotePort: uint16(67)}, false},
		}
		for _, c := range cases {
			got := decision(rules, layer, c.values) == wf.ActionPermit
			if got != c.permit {
				t.Errorf("%s/%s permit=%v", layer, c.name, got)
			}
		}
	}
	for _, r := range rules {
		if r.Persistent || r.Provider != provider || r.Sublayer != sublayer || r.HardAction != (r.Action == wf.ActionBlock) {
			t.Fatal("unsafe WFP ownership/lifetime/arbitration")
		}
	}
}

func TestForeignTunnelProtection(t *testing.T) {
	for _, item := range []adapter{{name: "mihomo", description: "Meta Tunnel", up: true}, {name: "Koala", description: "Wintun", up: true}, {name: "WireGuard", up: true}, {name: "custom", kind: 131, up: true}} {
		if !foreignTunnel(item) {
			t.Fatal("missed active foreign tunnel")
		}
	}
	for _, item := range []adapter{{name: "Nozelt", description: "Wintun", up: true}, {name: "mihomo", up: false}, {name: "Ethernet", description: "Realtek", up: true}, {name: "Radmin VPN", description: "Famatech", up: true}} {
		if foreignTunnel(item) {
			t.Fatal("misclassified adapter")
		}
	}
}
