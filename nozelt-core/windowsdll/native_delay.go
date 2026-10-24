//go:build windows

package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/net/proxy"
	"golang.org/x/sys/windows"
)

const (
	maxExternalDelayTargets     = 4096
	maxExternalDelayWorkers     = 8
	maxExternalDelayConfigBytes = 16 * 1024 * 1024
	maxExternalDelayInputBytes  = 64 * 1024 * 1024
)

type externalDelayTarget struct {
	Name   string `json:"name"`
	Config string `json:"config"`
	URL    string `json:"url"`
}

type externalDelayResult struct {
	Delay int    `json:"delay,omitempty"`
	Error string `json:"error,omitempty"`
}

type externalDelayEnvelope struct {
	OK      bool                           `json:"ok"`
	Results map[string]externalDelayResult `json:"results,omitempty"`
	Error   string                         `json:"error,omitempty"`
}

var activeExternalDelayTest = struct {
	sync.Mutex
	next    uint64
	cancels map[uint64]context.CancelFunc
}{cancels: make(map[uint64]context.CancelFunc)}

func testExternalProxyDelays(
	kind, targetsJSON string,
	timeoutMs int,
) string {
	return testExternalProxyDelaysStream(
		kind,
		targetsJSON,
		timeoutMs,
		nil,
	)
}

func testExternalProxyDelaysStream(
	kind, targetsJSON string,
	timeoutMs int,
	onResult func(name string, delay int),
) string {
	if kind != runtimeXray && kind != runtimeSingBox {
		return marshalExternalDelayEnvelope(externalDelayEnvelope{
			OK: false, Error: "unsupported native core",
		})
	}
	if len(targetsJSON) > maxExternalDelayInputBytes {
		return marshalExternalDelayEnvelope(externalDelayEnvelope{
			OK: false, Error: "native delay targets exceed the safe size limit",
		})
	}
	var targets []externalDelayTarget
	if err := json.Unmarshal([]byte(targetsJSON), &targets); err != nil ||
		len(targets) > maxExternalDelayTargets {
		return marshalExternalDelayEnvelope(externalDelayEnvelope{
			OK: false, Error: "invalid native delay targets",
		})
	}
	names := make(map[string]struct{}, len(targets))
	for _, target := range targets {
		if !validExternalDelayTarget(target, names) {
			return marshalExternalDelayEnvelope(externalDelayEnvelope{
				OK: false, Error: "invalid native delay target",
			})
		}
		names[target.Name] = struct{}{}
	}
	if len(targets) == 0 {
		return marshalExternalDelayEnvelope(externalDelayEnvelope{
			OK: true, Results: map[string]externalDelayResult{},
		})
	}
	if timeoutMs < 500 {
		timeoutMs = 500
	}
	if timeoutMs > 30000 {
		timeoutMs = 30000
	}

	ctx, cancel := context.WithCancel(context.Background())
	activeExternalDelayTest.Lock()
	activeExternalDelayTest.next++
	testID := activeExternalDelayTest.next
	activeExternalDelayTest.cancels[testID] = cancel
	activeExternalDelayTest.Unlock()
	defer func() {
		cancel()
		activeExternalDelayTest.Lock()
		delete(activeExternalDelayTest.cancels, testID)
		activeExternalDelayTest.Unlock()
	}()

	workerCount := min(maxExternalDelayWorkers, len(targets))
	jobs := make(chan externalDelayTarget)
	results := make(map[string]externalDelayResult, len(targets))
	var resultsMu sync.Mutex
	var workers sync.WaitGroup
	for range workerCount {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for target := range jobs {
				result := probeExternalCore(
					ctx,
					kind,
					target,
					time.Duration(timeoutMs)*time.Millisecond,
				)
				resultsMu.Lock()
				results[target.Name] = result
				resultsMu.Unlock()
				if onResult != nil {
					onResult(target.Name, result.Delay)
				}
			}
		}()
	}
sendTargets:
	for _, target := range targets {
		select {
		case jobs <- target:
		case <-ctx.Done():
			break sendTargets
		}
	}
	close(jobs)
	workers.Wait()
	for _, target := range targets {
		if _, found := results[target.Name]; !found {
			results[target.Name] = externalDelayResult{Error: "cancelled"}
		}
	}
	return marshalExternalDelayEnvelope(externalDelayEnvelope{
		OK: true, Results: results,
	})
}

func validExternalDelayTarget(
	target externalDelayTarget,
	names map[string]struct{},
) bool {
	if strings.TrimSpace(target.Name) == "" ||
		len(target.Config) == 0 ||
		len(target.Config) > maxExternalDelayConfigBytes {
		return false
	}
	if _, duplicate := names[target.Name]; duplicate {
		return false
	}
	parsed, err := url.Parse(target.URL)
	return err == nil &&
		(parsed.Scheme == "http" || parsed.Scheme == "https") &&
		parsed.Hostname() != "" &&
		parsed.User == nil
}

func cancelExternalDelayTests() {
	activeExternalDelayTest.Lock()
	cancels := make([]context.CancelFunc, 0, len(activeExternalDelayTest.cancels))
	for _, cancel := range activeExternalDelayTest.cancels {
		cancels = append(cancels, cancel)
	}
	activeExternalDelayTest.Unlock()
	for _, cancel := range cancels {
		cancel()
	}
}

func probeExternalCore(
	parent context.Context,
	kind string,
	target externalDelayTarget,
	timeout time.Duration,
) externalDelayResult {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return externalDelayResult{Error: "local probe unavailable"}
	}
	port := listener.Addr().(*net.TCPAddr).Port
	_ = listener.Close()

	config, err := externalProbeConfig(kind, target.Config, port)
	if err != nil {
		return externalDelayResult{Error: "invalid native probe config"}
	}
	command, job, done, err := startExternalProbe(kind, config)
	if err != nil {
		return externalDelayResult{Error: "native probe start failed"}
	}
	defer stopExternalProbe(command, job, done)

	startupContext, cancelStartup := context.WithTimeout(parent, 2500*time.Millisecond)
	err = waitForExternalProbe(startupContext, port, done)
	cancelStartup()
	if err != nil {
		return externalDelayResult{Error: "native probe startup failed"}
	}
	probeContext, cancelProbe := context.WithTimeout(parent, timeout)
	defer cancelProbe()
	delay, err := measureExternalDelay(probeContext, port, target.URL, timeout)
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return externalDelayResult{Error: "cancelled"}
		}
		return externalDelayResult{Error: "proxy test failed"}
	}
	return externalDelayResult{Delay: delay}
}

func externalProbeConfig(kind, raw string, port int) (string, error) {
	var document map[string]any
	if err := json.Unmarshal([]byte(raw), &document); err != nil {
		return "", err
	}
	// Match the live transport's anti-loop binding and built-in DNS strategy.
	// Only the probe child is created; the active TUN is never reconfigured.
	underlay, err := physicalInterface()
	if err != nil {
		return "", err
	}
	relay := relayConfig{Transport: document, underlay: underlay, port: port}
	prepared, err := relay.renderTransport(kind)
	if err != nil {
		return "", err
	}
	if err = json.Unmarshal([]byte(prepared), &document); err != nil {
		return "", err
	}
	switch kind {
	case runtimeXray:
		document["inbounds"] = []any{
			map[string]any{
				"tag": "nozelt-probe", "listen": "127.0.0.1",
				"port": port, "protocol": "socks",
				"settings": map[string]any{"auth": "noauth", "udp": false},
			},
		}
		document["log"] = map[string]any{"loglevel": "warning"}
	case runtimeSingBox:
		document["inbounds"] = []any{
			map[string]any{
				"type": "socks", "tag": "nozelt-probe",
				"listen": "127.0.0.1", "listen_port": port,
			},
		}
		document["log"] = map[string]any{
			"level": "warn", "timestamp": false,
		}
	default:
		return "", errors.New("unsupported native core")
	}
	encoded, err := json.Marshal(document)
	return string(encoded), err
}

func startExternalProbe(
	kind, config string,
) (*exec.Cmd, windowsJob, <-chan error, error) {
	executablePath, err := os.Executable()
	if err != nil {
		return nil, windowsJob{}, nil, err
	}
	directory := nativeCoreDirectory(executablePath)
	var executable string
	var arguments []string
	switch kind {
	case runtimeXray:
		executable = filepath.Join(directory, "xray.exe")
		arguments = []string{"run", "-c", "stdin:"}
	case runtimeSingBox:
		executable = filepath.Join(directory, "singbox-runner.exe")
		arguments = []string{"-"}
	default:
		return nil, windowsJob{}, nil, errors.New("unsupported native core")
	}
	command := exec.Command(executable, arguments...)
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	command.Stdin = strings.NewReader(config)
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	if kind == runtimeXray {
		command.Env = append(os.Environ(), "XRAY_LOCATION_ASSET="+directory)
	}
	if err = command.Start(); err != nil {
		return nil, windowsJob{}, nil, err
	}
	handle, err := createKillOnCloseJob(command.Process.Pid)
	if err != nil {
		_ = command.Process.Kill()
		_ = command.Wait()
		return nil, windowsJob{}, nil, err
	}
	done := make(chan error, 1)
	go func() {
		done <- command.Wait()
		close(done)
	}()
	return command, windowsJob{handle: handle}, done, nil
}

// A small wrapper prevents accidentally copying raw Windows handles into
// generic helper values.
type windowsJob struct {
	handle windows.Handle
}

func stopExternalProbe(
	command *exec.Cmd,
	job windowsJob,
	done <-chan error,
) {
	if job.handle != 0 {
		_ = windows.CloseHandle(job.handle)
	} else if command != nil && command.Process != nil {
		_ = command.Process.Kill()
	}
	select {
	case <-done:
	case <-time.After(2 * time.Second):
	}
}

func waitForExternalProbe(
	ctx context.Context,
	port int,
	done <-chan error,
) error {
	address := net.JoinHostPort("127.0.0.1", formatPort(port))
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	for {
		connection, err := net.DialTimeout("tcp4", address, 100*time.Millisecond)
		if err == nil {
			_ = connection.Close()
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-done:
			return errors.New("native core exited")
		case <-ticker.C:
		}
	}
}

func measureExternalDelay(
	ctx context.Context,
	port int,
	rawURL string,
	timeout time.Duration,
) (int, error) {
	socksDialer, err := proxy.SOCKS5(
		"tcp",
		net.JoinHostPort("127.0.0.1", formatPort(port)),
		nil,
		&net.Dialer{Timeout: timeout, KeepAlive: 30 * time.Second},
	)
	if err != nil {
		return 0, err
	}
	transport := &http.Transport{
		Proxy:                 nil,
		ForceAttemptHTTP2:     false,
		DisableCompression:    true,
		MaxIdleConns:          1,
		MaxIdleConnsPerHost:   1,
		IdleConnTimeout:       5 * time.Second,
		TLSHandshakeTimeout:   timeout,
		ResponseHeaderTimeout: timeout,
		TLSClientConfig:       &tls.Config{MinVersion: tls.VersionTLS12},
		DialContext: func(_ context.Context, network, address string) (net.Conn, error) {
			return socksDialer.Dial(network, address)
		},
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport}
	coldStarted := time.Now()
	if err = sendExternalDelayRequest(ctx, client, rawURL, false); err != nil {
		return 0, err
	}
	coldDelay := elapsedExternalMilliseconds(coldStarted)
	warmStarted := time.Now()
	if err = sendExternalDelayRequest(ctx, client, rawURL, true); err != nil {
		return coldDelay, nil
	}
	return elapsedExternalMilliseconds(warmStarted), nil
}

func sendExternalDelayRequest(
	ctx context.Context,
	client *http.Client,
	rawURL string,
	closeConnection bool,
) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodHead, rawURL, nil)
	if err != nil {
		return err
	}
	request.Header.Set("User-Agent", "Nozelt/1.0")
	request.Header.Set("Accept", "*/*")
	request.Close = closeConnection
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	_ = response.Body.Close()
	return nil
}

func elapsedExternalMilliseconds(started time.Time) int {
	elapsed := int(time.Since(started).Milliseconds())
	if elapsed < 1 {
		return 1
	}
	return elapsed
}

func formatPort(port int) string {
	return strconv.Itoa(port)
}

func marshalExternalDelayEnvelope(envelope externalDelayEnvelope) string {
	encoded, err := json.Marshal(envelope)
	if err != nil {
		return `{"ok":false,"error":"native delay response failed"}`
	}
	return string(encoded)
}
