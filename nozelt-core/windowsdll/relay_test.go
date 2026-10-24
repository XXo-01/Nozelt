//go:build windows

package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

func TestRelayTransportUsesAuthenticatedLoopbackAndBoundUnderlay(t *testing.T) {
	for _, kind := range []string{runtimeXray, runtimeSingBox} {
		t.Run(kind, func(t *testing.T) {
			relay := relayConfig{port: 54321, password: "random-test-secret", underlay: "Ethernet",
				Transport: map[string]any{"inbounds": []any{map[string]any{"type": "tun", "sniffing": map[string]any{"enabled": true, "destOverride": []any{"http", "tls", "quic"}}}},
					"outbounds": []any{map[string]any{"tag": "proxy", "protocol": "vless", "type": "vless"}},
					"routing":   map[string]any{"balancers": []any{map[string]any{"tag": "auto"}}}}}
			document, err := relay.renderTransport(kind)
			if err != nil {
				t.Fatal(err)
			}
			var value map[string]any
			json.Unmarshal([]byte(document), &value)
			inbound := value["inbounds"].([]any)[0].(map[string]any)
			if inbound["listen"] != "127.0.0.1" {
				t.Fatal("relay exposed outside loopback")
			}
			outbound := value["outbounds"].([]any)[0].(map[string]any)
			if kind == runtimeXray {
				if sniffing, ok := inbound["sniffing"].(map[string]any); !ok || sniffing["enabled"] != true {
					t.Fatal("provider domain/protocol sniffing lost when replacing listener")
				}
				settings := inbound["settings"].(map[string]any)
				if settings["auth"] != "password" {
					t.Fatal("unauthenticated relay")
				}
				sockopt := outbound["streamSettings"].(map[string]any)["sockopt"].(map[string]any)
				if sockopt["interface"] != "Ethernet" {
					t.Fatal("unbound transport can recurse into TUN")
				}
				if sockopt["domainStrategy"] != "ForceIPv4" {
					t.Fatal("transport can resolve its server into frontend fake IPs")
				}
				if value["routing"].(map[string]any)["balancers"] == nil {
					t.Fatal("lost provider balancer")
				}
			} else {
				if len(inbound["users"].([]any)) != 1 {
					t.Fatal("unauthenticated relay")
				}
				if outbound["bind_interface"] != "Ethernet" {
					t.Fatal("unbound transport")
				}
			}
			original := relay.Transport["inbounds"].([]any)[0].(map[string]any)
			if original["type"] != "tun" {
				t.Fatal("render mutated durable source")
			}
		})
	}
}

// Opt-in local integration: real binaries and authenticated SOCKS handshakes,
// without creating a TUN, changing routes, DNS, or contacting a VPN server.
func TestRelayChildRepeatedStartStop(t *testing.T) {
	if os.Getenv("NOZELT_NATIVE_CORE_DIR") == "" {
		t.Skip("native binaries not supplied")
	}
	underlay, err := physicalInterface()
	if err != nil {
		t.Fatal(err)
	}
	for _, kind := range []string{runtimeXray, runtimeSingBox} {
		t.Run(kind, func(t *testing.T) {
			for cycle := 0; cycle < 3; cycle++ {
				listener, err := net.Listen("tcp4", "127.0.0.1:0")
				if err != nil {
					t.Fatal(err)
				}
				port := listener.Addr().(*net.TCPAddr).Port
				listener.Close()
				outbound := map[string]any{"tag": "proxy", "protocol": "freedom"}
				if kind == runtimeSingBox {
					outbound = map[string]any{"tag": "proxy", "type": "direct"}
				}
				r := &windowsRuntime{kind: kind, relay: &relayConfig{port: port,
					password: "local-lifecycle-test", underlay: underlay,
					Transport: map[string]any{"outbounds": []any{outbound}, "log": map[string]any{"loglevel": "debug"}}}}
				if kind == runtimeSingBox {
					r.relay.Transport["log"] = map[string]any{"level": "debug"}
				} else {
					device, _ := net.InterfaceByName(underlay)
					addresses, _ := device.Addrs()
					for _, address := range addresses {
						ip, _, _ := net.ParseCIDR(address.String())
						if ip.To4() != nil && ip.IsGlobalUnicast() {
							r.relay.Transport["dns"] = map[string]any{
								"hosts":   map[string]any{"echo.nozelt.invalid": ip.String()},
								"servers": []any{}, "queryStrategy": "UseIPv4",
							}
							break
						}
					}
				}
				r.Lock()
				if err = r.startRelayChildLocked(); err != nil {
					r.Unlock()
					t.Fatal(err)
				}
				if !r.childAliveLocked() {
					r.stopChildLocked()
					r.Unlock()
					t.Fatal("child not alive")
				}
				domain := ""
				if kind == runtimeXray {
					domain = "echo.nozelt.invalid"
				}
				if err = checkRelayTCP(port, r.relay.password, underlay, domain); err != nil {
					r.stopChildLocked()
					r.Unlock()
					desktopLogs.Lock()
					for _, entry := range desktopLogs.entries {
						t.Log(entry.Message)
					}
					desktopLogs.Unlock()
					t.Fatal(err)
				}
				handle, err := windows.OpenProcess(windows.SYNCHRONIZE, false, uint32(r.command.Process.Pid))
				r.stopChildLocked()
				r.Unlock()
				if err != nil {
					t.Fatal(err)
				}
				outcome, err := windows.WaitForSingleObject(handle, uint32((2 * time.Second).Milliseconds()))
				windows.CloseHandle(handle)
				if err != nil || outcome != windows.WAIT_OBJECT_0 {
					t.Fatal("orphaned relay process", outcome, err)
				}
			}
		})
	}
}

func checkRelayTCP(port int, password, underlay, domain string) error {
	device, err := net.InterfaceByName(underlay)
	if err != nil {
		return err
	}
	addresses, err := device.Addrs()
	if err != nil {
		return err
	}
	var targetIP net.IP
	for _, address := range addresses {
		ip, _, _ := net.ParseCIDR(address.String())
		if ip.To4() != nil && ip.IsGlobalUnicast() {
			targetIP = ip.To4()
			break
		}
	}
	if targetIP == nil {
		return fmt.Errorf("no local IPv4 on selected underlay")
	}
	// Loopback cannot be the destination of Xray's physically bound sockets.
	// Use this machine's own underlay address; no remote host is contacted.
	listener, err := net.Listen("tcp4", net.JoinHostPort(targetIP.String(), "0"))
	if err != nil {
		return err
	}
	defer listener.Close()
	go func() {
		connection, err := listener.Accept()
		if err != nil {
			return
		}
		defer connection.Close()
		connection.SetDeadline(time.Now().Add(5 * time.Second))
		io.Copy(connection, connection)
	}()
	connection, err := net.DialTimeout("tcp4", "127.0.0.1:"+strconv.Itoa(port), time.Second)
	if err != nil {
		return err
	}
	defer connection.Close()
	connection.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err = connection.Write([]byte{5, 1, 2}); err != nil {
		return err
	}
	reply := make([]byte, 2)
	if _, err = io.ReadFull(connection, reply); err != nil {
		return err
	}
	if !bytes.Equal(reply, []byte{5, 2}) {
		return fmt.Errorf("SOCKS method: %v", reply)
	}
	auth := append([]byte{1, 6}, []byte("nozelt")...)
	auth = append(auth, byte(len(password)))
	auth = append(auth, []byte(password)...)
	if _, err = connection.Write(auth); err != nil {
		return err
	}
	if _, err = io.ReadFull(connection, reply); err != nil {
		return err
	}
	if !bytes.Equal(reply, []byte{1, 0}) {
		return fmt.Errorf("SOCKS auth: %v", reply)
	}
	targetPort := listener.Addr().(*net.TCPAddr).Port
	request := append([]byte{5, 1, 0, 1}, targetIP...)
	if domain != "" {
		// .invalid can only resolve through the configured built-in DNS hosts;
		// the old AsIs/system-DNS path cannot reach this local echo server.
		request = append([]byte{5, 1, 0, 3, byte(len(domain))}, []byte(domain)...)
	}
	request = append(request, byte(targetPort>>8), byte(targetPort))
	if _, err = connection.Write(request); err != nil {
		return err
	}
	header := make([]byte, 4)
	if _, err = io.ReadFull(connection, header); err != nil {
		return err
	}
	if header[1] != 0 {
		return fmt.Errorf("SOCKS connect: %v", header)
	}
	addressSize := 6
	if header[3] == 4 {
		addressSize = 18
	}
	if _, err = io.ReadFull(connection, make([]byte, addressSize)); err != nil {
		return err
	}
	// Reuse an established stream for enough chunks to expose stalls/data loss.
	payload := bytes.Repeat([]byte("Nozelt-local-transport-check"), 512)
	for chunk := 0; chunk < 64; chunk++ {
		if _, err = connection.Write(payload); err != nil {
			return err
		}
		actual := make([]byte, len(payload))
		if _, err = io.ReadFull(connection, actual); err != nil {
			return fmt.Errorf("relay payload chunk %d: %w", chunk, err)
		}
		if !bytes.Equal(payload, actual) {
			return fmt.Errorf("relay corrupted chunk %d", chunk)
		}
	}
	return nil
}

func TestRelayListenerOwnerIsThisProcess(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	pid, err := listenerOwner(listener.Addr().(*net.TCPAddr).Port)
	if err != nil {
		t.Fatal(err)
	}
	if int(pid) != os.Getpid() {
		t.Fatalf("owner %d, want %d", pid, os.Getpid())
	}
	if err := waitForRelay(listener.Addr().(*net.TCPAddr).Port, "x", 300*time.Millisecond, os.Getpid()+1); err == nil {
		t.Fatal("credentials must not go to a foreign listener")
	}
}
