//go:build windows

package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	tun "github.com/metacubex/sing-tun"
	"github.com/nozelt/nozelt-core/core"
	"golang.org/x/sys/windows"
)

type relayConfig struct {
	Version   int            `json:"nozeltWindowsRelay"`
	Transport map[string]any `json:"transport"`
	Frontend  map[string]any `json:"frontend"`
	port      int
	password  string
	underlay  string
}

func nativeCoreDirectory(executable string) string {
	if override := os.Getenv("NOZELT_NATIVE_CORE_DIR"); override != "" {
		return override
	}
	return filepath.Dir(executable)
}

func physicalInterface() (string, error) {
	if finder := dialer.DefaultInterfaceFinder.Load(); finder != nil {
		name := finder.FindInterfaceName(netip.MustParseAddr("1.1.1.1"))
		if name != "" && name != "<invalid>" {
			return name, nil
		}
	}
	// Before our frontend starts, a destination lookup can select another
	// VPN's split routes instead of the physical default. Use the same Windows
	// default-route monitor as Mihomo, which excludes virtual TUN interfaces.
	updates, err := tun.NewNetworkUpdateMonitor(log.SingLogger)
	if err != nil {
		return "", err
	}
	defer updates.Close()
	if err = updates.Start(); err != nil {
		return "", err
	}
	monitor, err := tun.NewDefaultInterfaceMonitor(updates, log.SingLogger,
		tun.DefaultInterfaceMonitorOptions{InterfaceFinder: sing_tun.DefaultInterfaceFinder})
	if err != nil {
		return "", err
	}
	defer monitor.Close()
	if err = monitor.Start(); err != nil {
		return "", err
	}
	if selected := monitor.DefaultInterface(); selected != nil && selected.Name != "" {
		return selected.Name, nil
	}
	return "", errors.New("physical network unavailable")
}

func decodeRelay(document string) (*relayConfig, error) {
	var relay relayConfig
	if err := json.Unmarshal([]byte(document), &relay); err != nil {
		return nil, err
	}
	if relay.Version != 1 || relay.Transport == nil || relay.Frontend == nil {
		return nil, errors.New("invalid Windows relay configuration")
	}
	if err := requireVerifiedTLS(relay.Transport["outbounds"]); err != nil {
		return nil, err
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	relay.port = listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	secret := make([]byte, 24)
	if _, err := rand.Read(secret); err != nil {
		return nil, err
	}
	relay.password = hex.EncodeToString(secret)
	relay.underlay, err = physicalInterface()
	if err != nil {
		return nil, err
	}
	proxies, ok := relay.Frontend["proxies"].([]any)
	if !ok || len(proxies) != 1 {
		return nil, errors.New("invalid relay frontend")
	}
	proxy, ok := proxies[0].(map[string]any)
	if !ok {
		return nil, errors.New("invalid relay outbound")
	}
	proxy["server"], proxy["port"] = "127.0.0.1", relay.port
	proxy["username"], proxy["password"] = "nozelt", relay.password
	// SOCKS is internal and authenticated; TUN still exposes no local inbounds.
	delete(proxy, "interface-name")
	return &relay, nil
}

func (relay *relayConfig) renderTransport(kind string) (string, error) {
	data, _ := json.Marshal(relay.Transport)
	var document map[string]any
	if err := json.Unmarshal(data, &document); err != nil {
		return "", err
	}
	if err := relay.applyEndpointDNSPolicies(kind, document); err != nil {
		return "", err
	}
	if kind == runtimeXray {
		document["log"] = map[string]any{"loglevel": "warning", "dnsLog": false}
		delete(document, "api")
		delete(document, "metrics")
		// Keep Nozelt's configured sniffing for provider protocol/domain rules.
		// Replacing only the listener must not silently disable route matching.
		var sniffing any
		if inbounds, ok := document["inbounds"].([]any); ok && len(inbounds) > 0 {
			if inbound, ok := inbounds[0].(map[string]any); ok {
				sniffing = inbound["sniffing"]
			}
		}
		document["inbounds"] = []any{map[string]any{
			"tag": "nozelt-tun", "listen": "127.0.0.1", "port": relay.port, "protocol": "socks",
			"settings": map[string]any{"auth": "password", "accounts": []any{map[string]any{
				"user": "nozelt", "pass": relay.password}}, "udp": true, "ip": "127.0.0.1"},
			"sniffing": sniffing,
		}}
		if outbounds, ok := document["outbounds"].([]any); ok {
			for _, value := range outbounds {
				outbound, ok := value.(map[string]any)
				if !ok {
					continue
				}
				stream, _ := outbound["streamSettings"].(map[string]any)
				if stream == nil {
					stream = map[string]any{}
					outbound["streamSettings"] = stream
				}
				socket, _ := stream["sockopt"].(map[string]any)
				if socket == nil {
					socket = map[string]any{}
					stream["sockopt"] = socket
				}
				socket["interface"] = relay.underlay
				// Never use system DNS once the frontend installs fake-IP DNS.
				// Force avoids falling back to that system resolver on failure.
				strategy := "ForceIPv4"
				if dns, ok := document["dns"].(map[string]any); ok && dns["queryStrategy"] == "UseIP" {
					strategy = "ForceIP"
				}
				socket["domainStrategy"] = strategy
			}
		}
	} else {
		document["log"] = map[string]any{"level": "warn", "timestamp": true}
		delete(document, "experimental")
		document["inbounds"] = []any{map[string]any{
			"type": "socks", "tag": "nozelt-tun", "listen": "127.0.0.1", "listen_port": relay.port,
			"users": []any{map[string]any{"username": "nozelt", "password": relay.password}},
		}}
		route, _ := document["route"].(map[string]any)
		if route == nil {
			route = map[string]any{}
			document["route"] = route
		}
		route["auto_detect_interface"] = true
		route["default_interface"] = relay.underlay
		if dns, ok := document["dns"].(map[string]any); ok {
			if servers, ok := dns["servers"].([]any); ok {
				for _, value := range servers {
					if server, ok := value.(map[string]any); ok {
						if detour, _ := server["detour"].(string); detour == "" {
							server["bind_interface"] = relay.underlay
						} else {
							delete(server, "bind_interface")
						}
					}
				}
			}
		}
		if outbounds, ok := document["outbounds"].([]any); ok {
			for _, value := range outbounds {
				if outbound, ok := value.(map[string]any); ok {
					if detour, _ := outbound["detour"].(string); detour == "" {
						outbound["bind_interface"] = relay.underlay
					} else {
						delete(outbound, "bind_interface")
					}
				}
			}
		}
	}
	data, err := json.Marshal(document)
	return string(data), err
}

// listenerOwner returns the process that listens on 127.0.0.1:port.
func listenerOwner(port int) (uint32, error) {
	const tcpTableOwnerPIDListener = 3
	iphlpapi := windows.NewLazySystemDLL("iphlpapi.dll")
	getTable := iphlpapi.NewProc("GetExtendedTcpTable")
	size := uint32(0)
	for attempt := 0; attempt < 4; attempt++ {
		var buffer []byte
		var pointer uintptr
		if size > 0 {
			buffer = make([]byte, size)
			pointer = uintptr(unsafe.Pointer(&buffer[0]))
		}
		status, _, _ := getTable.Call(pointer, uintptr(unsafe.Pointer(&size)), 0,
			windows.AF_INET, tcpTableOwnerPIDListener, 0)
		if status == uintptr(windows.ERROR_INSUFFICIENT_BUFFER) || buffer == nil {
			continue
		}
		if status != 0 {
			return 0, syscall.Errno(status)
		}
		count := *(*uint32)(unsafe.Pointer(&buffer[0]))
		// MIB_TCPROW_OWNER_PID: state, local address, local port, remote
		// address, remote port, owning PID; the port is in network order.
		rows := unsafe.Slice((*[6]uint32)(unsafe.Pointer(&buffer[4])), count)
		for _, row := range rows {
			local := uint16(row[2])
			if int(local>>8|local<<8) == port && row[1] == 0x0100007f {
				return row[5], nil
			}
		}
		return 0, errors.New("relay listener not found")
	}
	return 0, errors.New("relay listener table unavailable")
}

func waitForRelay(port int, password string, timeout time.Duration, owner int) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		// The password goes only to our own child. Another local process
		// that grabbed the port in the meantime gets nothing.
		if pid, err := listenerOwner(port); err != nil || int(pid) != owner {
			if err == nil {
				return errors.New("relay port taken by another process")
			}
			time.Sleep(50 * time.Millisecond)
			continue
		}
		connection, err := net.DialTimeout("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), 200*time.Millisecond)
		if err == nil {
			connection.SetDeadline(time.Now().Add(300 * time.Millisecond))
			// Verify the core actually accepts our authenticated SOCKS5 endpoint.
			_, err = connection.Write([]byte{5, 1, 2})
			reply := make([]byte, 2)
			if err == nil {
				_, err = io.ReadFull(connection, reply)
			}
			if err == nil && reply[0] == 5 && reply[1] == 2 {
				auth := append([]byte{1, 6}, []byte("nozelt")...)
				auth = append(auth, byte(len(password)))
				auth = append(auth, []byte(password)...)
				_, err = connection.Write(auth)
				if err == nil {
					_, err = io.ReadFull(connection, reply)
				}
				connection.Close()
				if err == nil && reply[0] == 1 && reply[1] == 0 {
					return nil
				}
			} else {
				connection.Close()
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	return errors.New("authenticated relay startup timed out")
}

func (r *windowsRuntime) startRelayChildLocked() error {
	path, err := os.Executable()
	if err != nil {
		return err
	}
	directory := nativeCoreDirectory(path)
	executable := filepath.Join(directory, "xray.exe")
	arguments := []string{"run", "-c", "stdin:"}
	if r.kind == runtimeSingBox {
		executable = filepath.Join(directory, "singbox-runner.exe")
		arguments = []string{"-"}
	}
	document, err := r.relay.renderTransport(r.kind)
	if err != nil {
		return err
	}
	if err = validateExternalConfig(r.kind, executable, directory, document); err != nil {
		return err
	}
	command := exec.Command(executable, arguments...)
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	command.Env = append(os.Environ(), "XRAY_LOCATION_ASSET="+directory)
	command.Stdin = strings.NewReader(document)
	writer := &externalCoreLogWriter{core: r.kind}
	command.Stdout, command.Stderr = writer, writer
	if err = command.Start(); err != nil {
		return err
	}
	job, err := createKillOnCloseJob(command.Process.Pid)
	if err != nil {
		command.Process.Kill()
		command.Wait()
		return err
	}
	r.command, r.job = command, job
	go r.wait(command)
	if err = waitForRelay(r.relay.port, r.relay.password, 5*time.Second, command.Process.Pid); err != nil {
		r.stopChildLocked()
		return err
	}
	return nil
}

func (r *windowsRuntime) startRelayLocked(kind, document string) error {
	relay, err := decodeRelay(document)
	if err != nil {
		return err
	}
	r.kind, r.relay = kind, relay
	if r.guard != nil {
		if err = r.guard.ProtectRelay(relay.port); err != nil {
			r.resetLocked()
			return err
		}
	}
	if err = r.startRelayChildLocked(); err != nil {
		r.resetLocked()
		return err
	}
	frontend, err := json.Marshal(relay.Frontend)
	if err == nil {
		err = core.SetNativeTun(true)
	}
	if err == nil {
		err = core.Start(string(frontend))
	}
	if err == nil && r.guard != nil {
		err = r.guard.PermitTun()
	}
	if err != nil {
		core.Stop()
		r.stopChildLocked()
		r.resetLocked()
		return err
	}
	r.startedAt = time.Now()
	r.mihomoFrontend.Store(true)
	r.relayCancel = make(chan struct{})
	go r.monitorRelay(r.relayCancel)
	return nil
}

func (r *windowsRuntime) stopChildLocked() {
	if r.job != 0 {
		windows.CloseHandle(r.job)
	} else if r.command != nil {
		r.command.Process.Kill()
	}
	r.command, r.job = nil, 0
}

// Changes of the physical default rebuild only the external transport. The
// same TUN stays installed while TCP/QUIC/DNS sessions recover on the underlay.
func (r *windowsRuntime) monitorRelay(cancel <-chan struct{}) {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	backoff := recoveryBackoff{}
	for {
		select {
		case <-cancel:
			return
		case <-ticker.C:
		}
		r.Lock()
		select {
		case <-cancel:
			r.Unlock()
			return
		default:
		}
		if r.relay == nil {
			r.Unlock()
			return
		}
		name, err := physicalInterface()
		if err == nil && (name != r.relay.underlay || r.command == nil) {
			if name != r.relay.underlay {
				backoff.reset()
			}
			if backoff.ready(time.Now()) {
				r.relay.underlay = name
				// Publish recovery before validation/start takes the runtime lock
				// for several seconds. Pollers must not reuse a healthy snapshot.
				var snapshot map[string]any
				json.Unmarshal([]byte(core.GetStatusJSON()), &snapshot)
				snapshot["running"], snapshot["recovering"] = false, true
				snapshot["networkGuard"] = r.guard != nil || r.persistedGuard
				encoded, _ := json.Marshal(snapshot)
				r.statusCache.Store(string(encoded))
				r.stopChildLocked()
				if err = r.startRelayChildLocked(); err == nil {
					err = core.RecoverNetwork()
					if err == nil {
						backoff.reset()
						desktopLogs.Log("info", "transport recovered on physical network")
					} else {
						desktopLogs.Log("error", "TUN network refresh failed; protection retained")
						r.stopChildLocked()
						backoff.failed(time.Now())
					}
				} else {
					backoff.failed(time.Now())
					desktopLogs.Log("error", "transport recovery failed; TUN retained")
				}
			}
		}
		r.Unlock()
	}
}
