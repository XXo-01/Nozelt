//go:build windows

// Package networkguard owns only Nozelt's WFP provider and filters.
package networkguard

import (
	"errors"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"unsafe"

	"github.com/tailscale/wf"
	"golang.org/x/sys/windows"
)

var provider = wf.ProviderID(windows.GUID{Data1: 0xd6488f91, Data2: 0x425d, Data3: 0x4b9e, Data4: [8]byte{0xa2, 0x28, 0x38, 0x51, 0x6d, 0x42, 0x8a, 0x51}})
var sublayer = wf.SublayerID(windows.GUID{Data1: 0xebf658f6, Data2: 0x889e, Data3: 0x45de, Data4: [8]byte{0xb9, 0xf4, 0x42, 0x18, 0xe5, 0xdc, 0x2c, 0x5f}})

type adapter struct {
	name, description string
	luid              uint64
	up                bool
	kind              uint32
}

func adapters() ([]adapter, error) {
	size := uint32(16384)
	for tries := 0; tries < 3; tries++ {
		buffer := make([]byte, size)
		first := (*windows.IpAdapterAddresses)(unsafe.Pointer(&buffer[0]))
		err := windows.GetAdaptersAddresses(windows.AF_UNSPEC, 0, 0, first, &size)
		if errors.Is(err, windows.ERROR_BUFFER_OVERFLOW) {
			continue
		}
		if err != nil {
			return nil, err
		}
		var result []adapter
		for a := first; a != nil; a = a.Next {
			result = append(result, adapter{windows.UTF16PtrToString(a.FriendlyName), windows.UTF16PtrToString(a.Description), a.Luid, a.OperStatus == windows.IfOperStatusUp, a.IfType})
		}
		return result, nil
	}
	return nil, errors.New("network inventory unavailable")
}

func foreignTunnel(a adapter) bool {
	// Nozelt's own adapters are "Nozelt", "Nozelt-Xray" and "Nozelt-sing-box".
	if !a.up || strings.HasPrefix(strings.ToLower(a.name), "nozelt") {
		return false
	}
	text := strings.ToLower(a.name + " " + a.description)
	// IF_TYPE_TUNNEL also covers Windows' own Teredo/IP-HTTPS/6to4 adapters,
	// which are not VPNs and must not block a connection.
	tunnelType := a.kind == 131 && !strings.HasPrefix(strings.ToLower(a.description), "microsoft")
	return tunnelType || strings.Contains(text, "wintun") || strings.Contains(text, "wireguard") || strings.Contains(text, "meta tunnel") || strings.Contains(text, "mihomo") || strings.Contains(text, "clash") || strings.Contains(text, "sing-box")
}

// ForeignVPNError reports another VPN that currently carries traffic. App is
// a display name: a known VPN program found running, or the adapter name.
type ForeignVPNError struct{ App string }

func (e *ForeignVPNError) Error() string { return "another VPN tunnel is active" }

// trafficRoutes returns the interfaces that own an Internet-sized route
// (IPv4 /16 or wider, IPv6 /32 or wider, multicast excluded). A tunnel left
// behind by a closed VPN, with only its own subnet, does not take traffic.
func trafficRoutes() (map[uint64]bool, error) {
	var table *windows.MibIpForwardTable2
	if err := windows.GetIpForwardTable2(windows.AF_UNSPEC, &table); err != nil {
		return nil, err
	}
	defer windows.FreeMibTable(unsafe.Pointer(table))
	result := make(map[uint64]bool)
	for _, row := range table.Rows() {
		prefix := row.DestinationPrefix
		first := byte(prefix.Prefix.Data[0])
		switch prefix.Prefix.Family {
		case windows.AF_INET:
			if prefix.PrefixLength <= 16 && first < 224 {
				result[row.InterfaceLuid] = true
			}
		case windows.AF_INET6:
			// Data[0] is sin6_flowinfo; the address starts at Data[1].
			first = byte(prefix.Prefix.Data[1])
			if prefix.PrefixLength <= 32 && first != 0xff {
				result[row.InterfaceLuid] = true
			}
		}
	}
	return result, nil
}

// knownVPNPrograms maps executable names to the name people see.
var knownVPNPrograms = map[string]string{
	"koala clash.exe": "Koala Clash", "clash-verge.exe": "Clash Verge",
	"clash verge.exe": "Clash Verge", "flclash.exe": "FlClash",
	"clash for windows.exe": "Clash for Windows", "mihomo-party.exe": "Mihomo Party",
	"hiddify.exe": "Hiddify", "v2rayn.exe": "v2rayN", "nekoray.exe": "NekoRay",
	"nekobox.exe": "NekoBox", "throne.exe": "Throne", "happ.exe": "Happ",
	"wireguard.exe": "WireGuard", "amneziavpn.exe": "AmneziaVPN",
	"amneziawg.exe": "AmneziaWG", "outline.exe": "Outline",
	"tailscale-ipn.exe": "Tailscale", "protonvpn.exe": "Proton VPN",
	"openvpn-gui.exe": "OpenVPN", "openvpn.exe": "OpenVPN",
	"karing.exe": "Karing", "invisible man xray.exe": "Invisible Man",
}

func runningVPNProgram() string {
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return ""
	}
	defer windows.CloseHandle(snapshot)
	var entry windows.ProcessEntry32
	entry.Size = uint32(unsafe.Sizeof(entry))
	for err = windows.Process32First(snapshot, &entry); err == nil; err = windows.Process32Next(snapshot, &entry) {
		name := strings.ToLower(windows.UTF16ToString(entry.ExeFile[:]))
		if app, ok := knownVPNPrograms[name]; ok {
			return app
		}
	}
	return ""
}

func displayAdapter(a adapter) string {
	name := strings.TrimSpace(a.name)
	if a.description != "" && !strings.EqualFold(a.description, name) {
		name += " (" + strings.TrimSpace(a.description) + ")"
	}
	if len([]rune(name)) > 64 {
		name = string([]rune(name)[:64])
	}
	return name
}

// CheckCompatibility is read-only. Never arm our policy over another VPN, but
// only one that is carrying traffic right now: leftover adapters of closed
// VPN programs must not block the connection.
func CheckCompatibility() error {
	items, err := adapters()
	if err != nil {
		return err
	}
	routes, routesErr := trafficRoutes()
	for _, a := range items {
		if !foreignTunnel(a) {
			continue
		}
		if routesErr == nil && !routes[a.luid] {
			continue
		}
		app := runningVPNProgram()
		if app == "" {
			app = displayAdapter(a)
		} else {
			app += ", " + displayAdapter(a)
		}
		return &ForeignVPNError{App: app}
	}
	return nil
}

type Guard struct {
	session   *wf.Session
	apps      []string
	ipv6      bool
	relayPort uint16
	tunLuid   uint64
}

// Arm blocks physical egress before TUN creation. The rules live in a dynamic
// WFP session: Windows deletes them as soon as the session closes or the host
// process exits for any reason, so a crash, a forced kill or a disconnect never
// leaves the computer without internet.
func Arm(executables []string, ipv6 bool) (*Guard, error) {
	if err := CheckCompatibility(); err != nil {
		return nil, err
	}
	var apps []string
	for _, path := range executables {
		id, err := wf.AppID(path)
		if err != nil {
			return nil, fmt.Errorf("network guard application identity: %w", err)
		}
		apps = append(apps, id)
	}
	s, err := wf.New(&wf.Options{Name: "Nozelt network protection", Dynamic: true})
	if err != nil {
		return nil, err
	}
	g := &Guard{session: s, apps: apps, ipv6: ipv6}
	err = s.Transaction(func() error {
		providers, err := s.Providers()
		if err != nil {
			return err
		}
		exists := false
		for _, p := range providers {
			if p.ID == provider {
				exists = true
			}
		}
		if !exists {
			if err = s.AddProvider(&wf.Provider{ID: provider, Name: "Nozelt network protection"}); err != nil {
				return err
			}
		}
		layers, err := s.Sublayers(provider)
		if err != nil {
			return err
		}
		exists = false
		for _, l := range layers {
			if l.ID == sublayer {
				exists = true
			}
		}
		if !exists {
			if err = s.AddSublayer(&wf.Sublayer{ID: sublayer, Provider: provider, Name: "Nozelt network protection", Weight: 0x8000}); err != nil {
				return err
			}
		}
		return g.replace(0)
	})
	if err != nil {
		s.Close()
		return nil, err
	}
	return g, nil
}

func match(field wf.FieldID, value any) *wf.Match {
	return &wf.Match{Field: field, Op: wf.MatchTypeEqual, Value: value}
}

// Policy keeps soft permits, allowing Windows Firewall to veto them. Only the
// deny action is hard. Separate filters avoid WFP's OR treatment of repeated
// conditions for the same field.
func policy(apps []string, tun uint64, ipv6 bool, dhcpApp string, relayPort uint16) []*wf.Rule {
	var rules []*wf.Rule
	for _, layer := range []wf.LayerID{wf.LayerALEAuthConnectV4, wf.LayerALEAuthConnectV6, wf.LayerALEAuthRecvAcceptV4, wf.LayerALEAuthRecvAcceptV6} {
		add := func(name string, weight uint64, action wf.Action, conditions ...*wf.Match) {
			rules = append(rules, &wf.Rule{Name: "Nozelt: " + name, Layer: layer, Sublayer: sublayer, Provider: provider, Weight: weight, Action: action, HardAction: action == wf.ActionBlock, Conditions: conditions})
		}
		add("deny bypass", 1, wf.ActionBlock)
		add("loopback", 100, wf.ActionPermit, &wf.Match{Field: wf.FieldFlags, Op: wf.MatchTypeFlagsAllSet, Value: wf.ConditionFlagIsLoopback})
		// Trusted transport executables still may not fall back to OS/plaintext
		// DNS on a physical adapter. DNS entering TUN is hijacked by the frontend.
		for _, protocol := range []uint8{6, 17} {
			add("deny physical plaintext DNS", 150, wf.ActionBlock,
				match(wf.FieldIPProtocol, protocol), match(wf.FieldIPRemotePort, uint16(53)),
				&wf.Match{Field: wf.FieldFlags, Op: wf.MatchTypeFlagsNoneSet, Value: wf.ConditionFlagIsLoopback},
				&wf.Match{Field: wf.FieldIPLocalInterface, Op: wf.MatchTypeNotEqual, Value: tun})
		}
		if layer == wf.LayerALEAuthConnectV4 && relayPort != 0 {
			add("private relay", 150, wf.ActionBlock, match(wf.FieldIPRemoteAddress, netip.MustParseAddr("127.0.0.1")), match(wf.FieldIPRemotePort, relayPort))
			for _, app := range apps {
				add("relay owner", 200, wf.ActionPermit, match(wf.FieldALEAppID, app), match(wf.FieldIPRemoteAddress, netip.MustParseAddr("127.0.0.1")), match(wf.FieldIPRemotePort, relayPort))
			}
		}
		v6 := layer == wf.LayerALEAuthConnectV6 || layer == wf.LayerALEAuthRecvAcceptV6
		if v6 && !ipv6 {
			continue
		}
		for _, app := range apps {
			add("transport", 100, wf.ActionPermit, match(wf.FieldALEAppID, app))
		}
		if tun != 0 {
			add("TUN", 100, wf.ActionPermit, match(wf.FieldIPLocalInterface, tun))
		}
		if dhcpApp != "" {
			local, remote := uint16(68), uint16(67)
			if v6 {
				local, remote = 546, 547
			}
			add("DHCP", 100, wf.ActionPermit, match(wf.FieldALEAppID, dhcpApp), match(wf.FieldIPProtocol, uint8(17)), match(wf.FieldIPLocalPort, local), match(wf.FieldIPRemotePort, remote))
		}
		if v6 {
			// Link-local IPv6 control only. No public echo/data exception and no
			// redirect messages. ICMP type/code alias local/remote port in WFP.
			types := []uint16{135, 136}
			if layer == wf.LayerALEAuthConnectV6 {
				types = append(types, 133)
			} else {
				types = append(types, 134)
			}
			for _, kind := range types {
				for _, prefix := range []string{"fe80::/10", "ff02::/16", "::/128"} {
					add("IPv6 neighbor discovery", 100, wf.ActionPermit, match(wf.FieldIPProtocol, uint8(58)), match(wf.FieldIPLocalPort, kind), match(wf.FieldIPRemotePort, uint16(0)), match(wf.FieldIPRemoteAddress, netip.MustParsePrefix(prefix)))
				}
			}
		}
	}
	return rules
}

func removeOwned(s *wf.Session) error {
	rules, err := ownedRules(s)
	if err != nil {
		return err
	}
	for _, r := range rules {
		if r.Provider == provider && r.Sublayer == sublayer {
			if err = s.DeleteRule(r.ID); err != nil {
				return err
			}
		}
	}
	return nil
}

func ownedRules(s *wf.Session) ([]*wf.Rule, error) {
	return s.RulesForProviderLayers(provider, wf.LayerALEAuthConnectV4, wf.LayerALEAuthConnectV6, wf.LayerALEAuthRecvAcceptV4, wf.LayerALEAuthRecvAcceptV6)
}

// Protected detects filters retained by an older, persistent build (or by a
// still-running session) without installing any filter.
func Protected() (bool, error) {
	s, err := wf.New(&wf.Options{Name: "Nozelt protection status"})
	if err != nil {
		return false, err
	}
	defer s.Close()
	rules, err := ownedRules(s)
	if err != nil {
		return false, err
	}
	layers := map[wf.LayerID]bool{}
	for _, rule := range rules {
		if rule.Provider == provider && rule.Sublayer == sublayer && rule.Action == wf.ActionBlock && len(rule.Conditions) == 0 && !rule.Disabled {
			layers[rule.Layer] = true
		}
	}
	return len(layers) == 4, nil
}

// Deterministic, reserved IDs also permit recovery with stock PowerShell when
// Defender has quarantined the application's executable or DLL.
func ruleID(index uint16) wf.RuleID {
	return wf.RuleID(windows.GUID{Data1: 0xa0d4ec71, Data2: 0x0967, Data3: 0x49a0, Data4: [8]byte{0x9e, 0x04, 0xf7, 0x1a, 0x19, 0x6b, byte(index >> 8), byte(index)}})
}

func (g *Guard) replace(tun uint64) error {
	if err := removeOwned(g.session); err != nil {
		return err
	}
	dhcpApp, err := wf.AppID(filepath.Join(os.Getenv("SystemRoot"), "System32", "svchost.exe"))
	if err != nil {
		return err
	}
	for index, rule := range policy(g.apps, tun, g.ipv6, dhcpApp, g.relayPort) {
		if index >= 512 {
			return errors.New("network policy exceeds recovery limit")
		}
		rule.ID = ruleID(uint16(index))
		if err = g.session.AddRule(rule); err != nil {
			return err
		}
	}
	return nil
}

// Reset rebuilds the base policy inside the live session. A second session
// must never be opened while this one exists: both would share the provider
// and sublayer, and closing the old session would delete objects that the
// new filters depend on.
func (g *Guard) Reset(executables []string, ipv6 bool) error {
	if err := CheckCompatibility(); err != nil {
		return err
	}
	var apps []string
	for _, path := range executables {
		id, err := wf.AppID(path)
		if err != nil {
			return fmt.Errorf("network guard application identity: %w", err)
		}
		apps = append(apps, id)
	}
	previousApps, previousIPv6, previousPort, previousTun := g.apps, g.ipv6, g.relayPort, g.tunLuid
	g.apps, g.ipv6, g.relayPort, g.tunLuid = apps, ipv6, 0, 0
	err := g.session.Transaction(func() error { return g.replace(0) })
	if err != nil {
		g.apps, g.ipv6, g.relayPort, g.tunLuid = previousApps, previousIPv6, previousPort, previousTun
	}
	return err
}

func (g *Guard) ProtectRelay(port int) error {
	if port < 1 || port > 65535 {
		return errors.New("invalid relay port")
	}
	previous := g.relayPort
	g.relayPort = uint16(port)
	err := g.session.Transaction(func() error { return g.replace(g.tunLuid) })
	if err != nil {
		g.relayPort = previous
	}
	return err
}

func (g *Guard) PermitTun() error {
	items, err := adapters()
	if err != nil {
		return err
	}
	for _, a := range items {
		if a.up && strings.EqualFold(a.name, "Nozelt") && a.luid != 0 {
			err := g.session.Transaction(func() error { return g.replace(a.luid) })
			if err == nil {
				g.tunLuid = a.luid
			}
			return err
		}
	}
	return errors.New("Nozelt TUN identity unavailable")
}

func (g *Guard) Close() error { return g.session.Close() }

// Release removes only our filters. It also works after a crash, from the
// standalone recovery tool. It never resets Windows Firewall or other VPNs.
func Release() error {
	s, err := wf.New(&wf.Options{Name: "Nozelt network recovery"})
	if err != nil {
		return err
	}
	defer s.Close()
	return s.Transaction(func() error { return removeOwned(s) })
}
