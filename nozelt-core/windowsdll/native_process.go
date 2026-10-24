//go:build windows

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	"github.com/nozelt/nozelt-core/core"
	"github.com/nozelt/nozelt-core/networkguard"
	"golang.org/x/sys/windows"
)

// How long a technical restart may keep the network block without a new
// session before it is released.
const restartGuardDeadline = 30 * time.Second

const (
	runtimeMihomo  = "mihomo"
	runtimeXray    = "xray"
	runtimeSingBox = "sing_box"
	stillActive    = 259
)

type windowsRuntime struct {
	sync.Mutex
	kind        string
	command     *exec.Cmd
	job         windows.Handle
	startedAt   time.Time
	lastError   error
	relay       *relayConfig
	frontend    map[string]any
	relayCancel chan struct{}
	guard       *networkguard.Guard
	guardProbed bool
	// Counts technical stops. A stop that keeps the block for a restart arms
	// a deadline; a start or a later stop makes that deadline obsolete.
	restartGeneration uint64
	persistedGuard    bool
	statusCache       atomic.Value
	mihomoFrontend    atomic.Bool
	trafficCache      atomic.Value

	trafficAlias       string
	trafficBaselineSet bool
	baseUpload         uint64
	baseDownload       uint64
	lastUpload         uint64
	lastDownload       uint64
	lastTrafficAt      time.Time
}

var desktopRuntime = &windowsRuntime{}

type externalCoreLogWriter struct {
	sync.Mutex
	core    string
	pending []byte
}

func (w *externalCoreLogWriter) Write(value []byte) (int, error) {
	w.Lock()
	w.pending = append(w.pending, value...)
	lines := make([]string, 0, 2)
	for {
		index := bytes.IndexByte(w.pending, '\n')
		if index < 0 {
			break
		}
		line := strings.TrimSpace(string(w.pending[:index]))
		w.pending = w.pending[index+1:]
		if line != "" {
			if len(line) > 4096 {
				line = line[:4096]
			}
			lines = append(lines, line)
		}
	}
	if len(w.pending) > 8192 {
		w.pending = append([]byte(nil), w.pending[len(w.pending)-4096:]...)
	}
	w.Unlock()
	for _, line := range lines {
		level := "warning"
		lower := strings.ToLower(line)
		if strings.Contains(lower, "error") ||
			strings.Contains(lower, "failed") ||
			strings.Contains(lower, "fatal") {
			level = "error"
		}
		desktopLogs.Log(level, w.core+": "+line)
	}
	return len(value), nil
}

func (r *windowsRuntime) start(kind, config string) error {
	r.Lock()
	defer r.Unlock()
	return r.startLocked(kind, config)
}

func (r *windowsRuntime) startLocked(kind, config string) (err error) {
	if r.runningLocked() || core.IsRunning() {
		return core.ErrAlreadyRunning
	}
	r.restartGeneration++
	// Any failed start, including one after a technical restart, releases
	// the block: a disconnected Nozelt must never keep the PC offline.
	defer func() {
		if err != nil {
			r.releaseGuardLocked()
		}
	}()
	// Every supported Windows core creates a native adapter and mutates the
	// system route table. Reject an unelevated host before a third-party core
	// partially applies its configuration; this also gives Flutter a precise,
	// actionable error instead of the generic "tun failed" fallback.
	if !windows.GetCurrentProcessToken().IsElevated() {
		return errors.New("administrator required")
	}
	frontend, err := windowsFrontend(kind, config)
	if err != nil {
		return err
	}
	if err = validateWindowsFrontend(frontend); err != nil {
		return err
	}
	hostExecutable, err := os.Executable()
	if err != nil {
		return err
	}
	apps := []string{hostExecutable}
	if kind != runtimeMihomo {
		directory := filepath.Dir(hostExecutable)
		if override := os.Getenv("NOZELT_NATIVE_CORE_DIR"); override != "" {
			directory = override
		}
		name := "xray.exe"
		if kind == runtimeSingBox {
			name = "singbox-runner.exe"
		}
		apps = append(apps, filepath.Join(directory, name))
	}
	// Protection precedes routes; one transaction replaces our own filters.
	// A guard kept across a technical restart is rebuilt in its own session.
	if r.guard != nil {
		if err = r.guard.Reset(apps, frontend["ipv6"] == true); err != nil {
			return fmt.Errorf("network protection failed: %w", err)
		}
	} else {
		nextGuard, armErr := networkguard.Arm(apps, frontend["ipv6"] == true)
		if armErr != nil {
			return fmt.Errorf("network protection failed: %w", armErr)
		}
		r.guard = nextGuard
	}
	r.stopChildLocked()
	r.resetLocked()
	switch kind {
	case runtimeMihomo:
		if err = core.SetNativeTun(true); err != nil {
			return err
		}
		if err = core.Start(config); err != nil {
			return err
		}
		r.kind = kind
		r.frontend = frontend
		r.startedAt = time.Now()
		if err = r.guard.PermitTun(); err != nil {
			core.Stop()
			r.resetLocked()
			return err
		}
		r.mihomoFrontend.Store(true)
		return nil
	case runtimeXray, runtimeSingBox:
		var envelope map[string]any
		if json.Unmarshal([]byte(config), &envelope) == nil && envelope["nozeltWindowsRelay"] != nil {
			err = r.startRelayLocked(kind, config)
			return err
		}
	default:
		return errors.New("unsupported core")
	}

	executableDirectory, err := os.Executable()
	if err != nil {
		return errors.New("runtime path unavailable")
	}
	executableDirectory = filepath.Dir(executableDirectory)
	var executable string
	var arguments []string
	var alias string
	if kind == runtimeXray {
		executable = filepath.Join(executableDirectory, "xray.exe")
		arguments = []string{"run", "-c", "stdin:"}
		alias = "xray"
	} else {
		executable = filepath.Join(executableDirectory, "singbox-runner.exe")
		arguments = []string{"-"}
		alias = "sing-box"
	}
	if _, statErr := os.Stat(executable); statErr != nil {
		return errors.New("native core executable unavailable")
	}
	if err = validateExternalConfig(kind, executable, executableDirectory, config); err != nil {
		return err
	}

	command := exec.Command(executable, arguments...)
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if kind == runtimeXray {
		command.Env = append(
			os.Environ(),
			"XRAY_LOCATION_ASSET="+executableDirectory,
		)
	}
	logWriter := &externalCoreLogWriter{core: kind}
	command.Stdout = logWriter
	command.Stderr = logWriter
	stdin, err := command.StdinPipe()
	if err != nil {
		return errors.New("native core input unavailable")
	}
	if err = command.Start(); err != nil {
		_ = stdin.Close()
		return errors.New("native core start failed")
	}
	if _, err = io.WriteString(stdin, config); err != nil {
		_ = stdin.Close()
		_ = command.Process.Kill()
		return errors.New("native core configuration failed")
	}
	if err = stdin.Close(); err != nil {
		_ = command.Process.Kill()
		return errors.New("native core configuration failed")
	}

	job, err := createKillOnCloseJob(command.Process.Pid)
	if err != nil {
		_ = command.Process.Kill()
		return errors.New("native core containment failed")
	}
	expectedInterface := "Nozelt-Xray"
	if kind == runtimeSingBox {
		expectedInterface = "Nozelt-sing-box"
	}
	if err = waitForExternalTun(command, expectedInterface, 5*time.Second); err != nil {
		_ = windows.CloseHandle(job)
		_ = command.Process.Kill()
		_ = command.Wait()
		return err
	}
	r.kind = kind
	r.command = command
	r.job = job
	r.startedAt = time.Now()
	r.trafficAlias = alias
	r.lastError = nil
	go r.wait(command)
	return nil
}

// Xray and sing-box start asynchronously. A successful CreateProcess only
// proves that their config parser accepted stdin; it does not prove that the
// Wintun adapter or routes came up. Wait for the interface before reporting
// success so Flutter never displays a false "connected" state.
func waitForExternalTun(
	command *exec.Cmd,
	interfaceName string,
	timeout time.Duration,
) error {
	processHandle, err := windows.OpenProcess(
		windows.PROCESS_QUERY_LIMITED_INFORMATION,
		false,
		uint32(command.Process.Pid),
	)
	if err != nil {
		return errors.New("native core status unavailable")
	}
	defer windows.CloseHandle(processHandle)
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		var exitCode uint32
		if err := windows.GetExitCodeProcess(processHandle, &exitCode); err != nil {
			return errors.New("native core status unavailable")
		}
		if exitCode != stillActive {
			return errors.New("native core tun failed")
		}
		interfaces, err := net.Interfaces()
		if err == nil {
			for _, networkInterface := range interfaces {
				if strings.EqualFold(networkInterface.Name, interfaceName) {
					return nil
				}
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	return errors.New("native core tun startup timed out")
}

func validateExternalConfig(
	kind, executable, executableDirectory, config string,
) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var arguments []string
	switch kind {
	case runtimeXray:
		arguments = []string{"run", "-test", "-c", "stdin:"}
	case runtimeSingBox:
		arguments = []string{"--check", "-"}
	default:
		return errors.New("unsupported core")
	}
	command := exec.CommandContext(ctx, executable, arguments...)
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	command.Stdin = strings.NewReader(config)
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	if kind == runtimeXray {
		command.Env = append(
			os.Environ(),
			"XRAY_LOCATION_ASSET="+executableDirectory,
		)
	}
	if err := command.Run(); err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return errors.New("native core config validation timed out")
		}
		return errors.New("native core config validation failed")
	}
	return nil
}

func createKillOnCloseJob(pid int) (windows.Handle, error) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return 0, err
	}
	information := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	information.BasicLimitInformation.LimitFlags =
		windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err = windows.SetInformationJobObject(
		job,
		windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&information)),
		uint32(unsafe.Sizeof(information)),
	); err != nil {
		windows.CloseHandle(job)
		return 0, err
	}
	process, err := windows.OpenProcess(
		windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE,
		false,
		uint32(pid),
	)
	if err != nil {
		windows.CloseHandle(job)
		return 0, err
	}
	defer windows.CloseHandle(process)
	if err = windows.AssignProcessToJobObject(job, process); err != nil {
		windows.CloseHandle(job)
		return 0, err
	}
	return job, nil
}

func (r *windowsRuntime) wait(command *exec.Cmd) {
	err := command.Wait()
	r.Lock()
	defer r.Unlock()
	if r.command != command {
		return
	}
	if r.job != 0 {
		windows.CloseHandle(r.job)
	}
	r.command = nil
	r.job = 0
	if r.relay == nil {
		r.startedAt = time.Time{}
	}
	r.lastError = err
	r.trafficBaselineSet = false
	if err != nil {
		desktopLogs.Log("error", r.kind+" stopped unexpectedly")
	}
}

func (r *windowsRuntime) stop() error { return r.stopMode(false) }

func (r *windowsRuntime) stopMode(restarting bool) (result error) {
	r.Lock()
	defer r.Unlock()
	stopCore := core.Stop
	if restarting {
		stopCore = core.StopForRestart
	}
	r.restartGeneration++
	defer func() {
		if restarting {
			// The block is kept only while the replacement start is on its
			// way. If none arrives, never leave the PC offline.
			generation := r.restartGeneration
			time.AfterFunc(restartGuardDeadline, func() {
				r.Lock()
				defer r.Unlock()
				if r.restartGeneration == generation && r.guard != nil && !r.runningLocked() && !core.IsRunning() {
					desktopLogs.Log("warning", "restart did not finish; network protection released")
					r.releaseGuardLocked()
				}
			})
			return
		}
		// Closing our dynamic session alone removes every filter it owns, so
		// do it first and unconditionally. Release only sweeps leftovers of
		// older persistent builds and never keeps the PC offline on failure.
		r.releaseGuardLocked()
	}()
	if r.relay != nil {
		err := stopCore()
		r.stopChildLocked()
		r.resetLocked()
		if errors.Is(err, core.ErrNotRunning) {
			return nil
		}
		return err
	}
	if !r.runningLocked() {
		r.resetLocked()
		return nil
	}
	if r.kind == runtimeMihomo {
		err := stopCore()
		if errors.Is(err, core.ErrNotRunning) {
			err = nil
		}
		r.resetLocked()
		return err
	}
	if r.job != 0 {
		_ = windows.CloseHandle(r.job)
	} else if r.command != nil && r.command.Process != nil {
		_ = r.command.Process.Kill()
	}
	r.command = nil
	r.job = 0
	r.resetLocked()
	return nil
}

func (r *windowsRuntime) reload(config string) error {
	r.Lock()
	defer r.Unlock()
	frontend, err := windowsFrontend(r.kind, config)
	if err != nil {
		return err
	}
	if err = validateWindowsFrontend(frontend); err != nil {
		return err
	}
	previous := r.frontend
	if r.relay != nil {
		previous = r.relay.Frontend
	}
	if err = validateRoutingOnlyReload(previous, frontend); err != nil {
		return err
	}
	if r.relay != nil {
		var next relayConfig
		if json.Unmarshal([]byte(config), &next) != nil || next.Version != 1 {
			return errors.New("invalid relay config")
		}
		// Routing-only edits update the common TUN layer without stopping transport.
		oldTransport, _ := json.Marshal(r.relay.Transport)
		newTransport, _ := json.Marshal(next.Transport)
		if !bytes.Equal(oldTransport, newTransport) {
			return errors.New("transport change requires restart")
		}
		next.port, next.password, next.underlay = r.relay.port, r.relay.password, r.relay.underlay
		proxies, ok := next.Frontend["proxies"].([]any)
		if !ok || len(proxies) != 1 {
			return errors.New("invalid relay frontend")
		}
		proxy, ok := proxies[0].(map[string]any)
		if !ok {
			return errors.New("invalid relay frontend")
		}
		proxy["server"], proxy["port"], proxy["username"], proxy["password"] = "127.0.0.1", next.port, "nozelt", next.password
		frontend, _ := json.Marshal(next.Frontend)
		if err := core.ReloadConfig(string(frontend)); err != nil {
			return err
		}
		r.relay = &next
		if r.guard != nil {
			if err := r.guard.PermitTun(); err != nil {
				r.failReloadLocked()
				return err
			}
		}
		return nil
	}
	if !r.runningLocked() {
		return core.ErrNotRunning
	}
	if r.kind == runtimeMihomo {
		if err := core.ReloadConfig(config); err != nil {
			return err
		}
		r.frontend = frontend
		if r.guard != nil {
			if err := r.guard.PermitTun(); err != nil {
				r.failReloadLocked()
				return err
			}
		}
		return nil
	}
	kind := r.kind
	if r.job != 0 {
		_ = windows.CloseHandle(r.job)
	} else if r.command != nil && r.command.Process != nil {
		_ = r.command.Process.Kill()
	}
	r.command = nil
	r.job = 0
	r.resetLocked()
	return r.startLocked(kind, config)
}

// failReloadLocked stops a session whose TUN could not be re-authorized
// after a reload. The session is gone, so the block goes with it.
func (r *windowsRuntime) failReloadLocked() {
	core.Stop()
	r.stopChildLocked()
	r.resetLocked()
	r.releaseGuardLocked()
}

func (r *windowsRuntime) runningLocked() bool {
	if r.relay != nil {
		return core.IsRunning() && r.childAliveLocked()
	}
	if r.kind == runtimeMihomo {
		return core.IsRunning()
	}
	return r.childAliveLocked()
}

func (r *windowsRuntime) childAliveLocked() bool {
	if r.command == nil {
		return false
	}
	handle, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(r.command.Process.Pid))
	if err != nil {
		return false
	}
	defer windows.CloseHandle(handle)
	var code uint32
	return windows.GetExitCodeProcess(handle, &code) == nil && code == stillActive
}

func (r *windowsRuntime) resetLocked() {
	if r.relayCancel != nil {
		close(r.relayCancel)
		r.relayCancel = nil
	}
	r.relay = nil
	r.frontend = nil
	r.kind = ""
	r.mihomoFrontend.Store(false)
	r.command = nil
	r.job = 0
	r.startedAt = time.Time{}
	r.trafficAlias = ""
	r.trafficBaselineSet = false
	r.baseUpload = 0
	r.baseDownload = 0
	r.lastUpload = 0
	r.lastDownload = 0
	r.lastTrafficAt = time.Time{}
}

// releaseGuardLocked removes the network block of this process and any
// filters left by older persistent builds.
func (r *windowsRuntime) releaseGuardLocked() {
	if r.guard != nil {
		if err := r.guard.Close(); err != nil {
			desktopLogs.Log("warning", "network protection session close failed")
		}
		r.guard = nil
	}
	r.guardProbed = true
	if protected, err := networkguard.Protected(); err != nil || protected {
		if networkguard.Release() != nil {
			desktopLogs.Log("error", "network protection cleanup failed")
			r.persistedGuard = true
			return
		}
	}
	r.persistedGuard = false
}

func (r *windowsRuntime) probeGuardLocked() {
	if r.guardProbed {
		return
	}
	r.guardProbed = true
	if protected, err := networkguard.Protected(); err == nil {
		r.persistedGuard = protected
	}
	// Filters left behind by an older persistent build must never keep the
	// computer offline: without a live session of ours, release them at once.
	if r.persistedGuard && r.guard == nil {
		if networkguard.Release() == nil {
			r.persistedGuard = false
		}
	}
}

func (r *windowsRuntime) statusJSON() string {
	if !r.TryLock() {
		if cached := r.statusCache.Load(); cached != nil {
			return cached.(string)
		}
		return core.GetStatusJSON()
	}
	defer r.Unlock()
	r.probeGuardLocked()
	guardOn := r.guard != nil || r.persistedGuard
	var status map[string]any
	if r.relay != nil {
		json.Unmarshal([]byte(core.GetStatusJSON()), &status)
		status["running"] = r.runningLocked()
		status["recovering"] = core.IsRunning() && !r.childAliveLocked()
		status["networkGuard"] = guardOn
		encoded, _ := json.Marshal(status)
		r.statusCache.Store(string(encoded))
		return string(encoded)
	}
	if r.kind == runtimeMihomo {
		json.Unmarshal([]byte(core.GetStatusJSON()), &status)
		status["networkGuard"] = guardOn
		encoded, _ := json.Marshal(status)
		r.statusCache.Store(string(encoded))
		return string(encoded)
	}
	running := r.runningLocked()
	started := int64(0)
	uptime := int64(0)
	if running {
		started = r.startedAt.Unix()
		uptime = int64(time.Since(r.startedAt).Seconds())
	}
	value := map[string]any{
		"networkGuard":      guardOn,
		"running":           running,
		"startedAtUnix":     started,
		"uptimeSeconds":     uptime,
		"mihomoVersion":     core.MihomoVersion(),
		"nozeltCoreVersion": core.NozeltCoreVersion,
		"mode":              "",
		"listeners": map[string]int{
			"mixedPort": 0, "httpPort": 0, "socksPort": 0,
			"redirPort": 0, "tproxyPort": 0,
		},
		"connectionsCount":    0,
		"tun":                 map[string]any{"enabled": running, "stack": "", "fd": 0},
		"openFileDescriptors": -1,
		"goRoutines":          0,
		"socketProtection":    false,
		"protectedSockets":    0,
		"protectionFailures":  0,
	}
	encoded, _ := json.Marshal(value)
	r.statusCache.Store(string(encoded))
	return string(encoded)
}

func (r *windowsRuntime) trafficJSON() string {
	if !r.TryLock() {
		if cached := r.trafficCache.Load(); cached != nil {
			return cached.(string)
		}
		return core.GetTrafficJSON()
	}
	defer r.Unlock()
	if r.kind == runtimeMihomo || r.relay != nil {
		value := core.GetTrafficJSON()
		r.trafficCache.Store(value)
		return value
	}
	traffic := map[string]any{
		"uploadBytes": 0, "downloadBytes": 0,
		"uploadSpeedBps": 0, "downloadSpeedBps": 0,
		"activeConnections": 0, "synthetic": false,
	}
	if !r.runningLocked() {
		encoded, _ := json.Marshal(traffic)
		return string(encoded)
	}
	upload, download, ok := interfaceOctets(r.trafficAlias)
	if !ok {
		encoded, _ := json.Marshal(traffic)
		return string(encoded)
	}
	now := time.Now()
	if !r.trafficBaselineSet {
		r.trafficBaselineSet = true
		r.baseUpload, r.baseDownload = upload, download
		r.lastUpload, r.lastDownload = upload, download
		r.lastTrafficAt = now
	} else {
		elapsed := now.Sub(r.lastTrafficAt).Seconds()
		if elapsed > 0 {
			traffic["uploadSpeedBps"] =
				int64(float64(counterDelta(upload, r.lastUpload)) / elapsed)
			traffic["downloadSpeedBps"] =
				int64(float64(counterDelta(download, r.lastDownload)) / elapsed)
		}
		traffic["uploadBytes"] = int64(counterDelta(upload, r.baseUpload))
		traffic["downloadBytes"] = int64(counterDelta(download, r.baseDownload))
		r.lastUpload, r.lastDownload = upload, download
		r.lastTrafficAt = now
	}
	encoded, _ := json.Marshal(traffic)
	return string(encoded)
}

func counterDelta(current, previous uint64) uint64 {
	if current < previous {
		return current
	}
	return current - previous
}

func interfaceOctets(coreAlias string) (upload uint64, download uint64, ok bool) {
	var table *windows.MibIfTable2
	if err := windows.GetIfTable2Ex(windows.MibIfTableNormal, &table); err != nil {
		return 0, 0, false
	}
	defer windows.FreeMibTable(unsafe.Pointer(table))
	rows := unsafe.Slice(&table.Table[0], int(table.NumEntries))
	needle := strings.ToLower(coreAlias)
	for index := range rows {
		alias := strings.ToLower(windows.UTF16ToString(rows[index].Alias[:]))
		description := strings.ToLower(
			windows.UTF16ToString(rows[index].Description[:]),
		)
		if strings.Contains(alias, "nozelt") &&
			(strings.Contains(alias, needle) || strings.Contains(description, needle)) {
			return rows[index].OutOctets, rows[index].InOctets, true
		}
	}
	return 0, 0, false
}

// isMihomo is called from the UI thread. While a start or a transport
// recovery holds the lock for seconds, answer from the last known value
// instead of freezing the window.
func (r *windowsRuntime) isMihomo() bool {
	if !r.TryLock() {
		return r.mihomoFrontend.Load()
	}
	defer r.Unlock()
	value := r.kind == runtimeMihomo || r.relay != nil
	r.mihomoFrontend.Store(value)
	return value
}
