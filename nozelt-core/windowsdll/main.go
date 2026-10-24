//go:build windows

// Package main builds the portable Windows C ABI used by Flutter through
// dart:ffi. Complex values remain UTF-8 JSON exactly like the gomobile ABI.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
	"unicode/utf16"
	"unsafe"

	"github.com/metacubex/mihomo/component/updater"
	CConstant "github.com/metacubex/mihomo/constant"
	"github.com/nozelt/nozelt-core/core"
	"github.com/nozelt/nozelt-core/logger"
	"github.com/nozelt/nozelt-core/networkguard"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

const maxDesktopLogs = 2000

type desktopLogEntry struct {
	Level       string `json:"level"`
	Message     string `json:"message"`
	TimestampMs int64  `json:"timestampMs"`
	// Grows with every entry, so a reader can tell new lines from old ones
	// after the buffer is full and starts dropping its oldest lines.
	Sequence uint64 `json:"seq"`
}

type desktopLogBuffer struct {
	sync.Mutex
	entries []desktopLogEntry
	next    uint64
}

var desktopLogs = &desktopLogBuffer{entries: make([]desktopLogEntry, 0, 256)}

func (b *desktopLogBuffer) Log(level, message string) {
	entry := desktopLogEntry{
		Level:       level,
		Message:     privateLogMessage(message),
		TimestampMs: time.Now().UnixMilli(),
	}
	b.Lock()
	b.next++
	entry.Sequence = b.next
	if len(b.entries) >= maxDesktopLogs {
		copy(b.entries, b.entries[len(b.entries)-maxDesktopLogs+1:])
		b.entries = b.entries[:maxDesktopLogs-1]
	}
	b.entries = append(b.entries, entry)
	b.Unlock()
}

func init() {
	logger.Set(desktopLogs)
	if executable, err := os.Executable(); err == nil {
		directory := filepath.Join(filepath.Dir(executable), "portable-data", "core")
		if override := os.Getenv("NOZELT_DATA_DIR"); override != "" {
			directory = filepath.Join(override, "core")
		}
		if os.MkdirAll(directory, 0700) == nil {
			CConstant.SetHomeDir(directory)
			// Seed versioned bundled geodata. Never overwrite a user-updated database.
			for _, name := range []string{"geoip.dat", "geosite.dat"} {
				destination := filepath.Join(directory, name)
				if _, err := os.Stat(destination); os.IsNotExist(err) {
					if data, err := os.ReadFile(filepath.Join(filepath.Dir(executable), name)); err == nil {
						os.WriteFile(destination, data, 0600)
					}
				}
			}
		}
	}
}

func main() {}

func cString(value string) *C.char { return C.CString(value) }

func resultJSON(err error) string {
	if err == nil {
		return `{"ok":true}`
	}
	// Third-party errors can contain a proxy endpoint or credential-bearing
	// option. Keep the cross-process failure category deterministic.
	category := "operation failed"
	message := strings.ToLower(err.Error())
	switch {
	case errors.Is(err, core.ErrAlreadyRunning):
		category = "already running"
	case errors.Is(err, core.ErrNotRunning):
		category = "not running"
	case strings.Contains(message, "another vpn"):
		category = "another_vpn_active"
	case strings.Contains(message, "network protection"):
		category = "network_guard_failed"
	case strings.Contains(message, "tls certificate verification"):
		category = "tls_verification_required"
	case strings.Contains(message, "provider process rules"):
		category = "provider_process_rules_unsupported"
	case strings.Contains(message, "administrator"),
		strings.Contains(message, "access is denied"),
		strings.Contains(message, "permission denied"):
		category = "administrator_required"
	case strings.Contains(message, "tun"):
		category = "tun failed"
	case strings.Contains(message, "config"), strings.Contains(message, "parse"):
		category = "invalid config"
	}
	result := map[string]any{"ok": false, "error": category}
	// The other VPN's program/adapter name is local display text, never a
	// proxy endpoint or credential, so the UI may show it.
	var foreign *networkguard.ForeignVPNError
	if errors.As(err, &foreign) && foreign.App != "" {
		result["error"] = "another_vpn_active"
		result["detail"] = foreign.App
	}
	encoded, _ := json.Marshal(result)
	return string(encoded)
}

var dpapiEntropy = []byte("Nozelt Windows profile store v1")

var (
	comdlg32                  = windows.NewLazySystemDLL("comdlg32.dll")
	procGetOpenFileNameW      = comdlg32.NewProc("GetOpenFileNameW")
	procCommDlgExtendedErrorW = comdlg32.NewProc("CommDlgExtendedError")
)

type openFileNameW struct {
	StructSize      uint32
	Owner           windows.Handle
	Instance        windows.Handle
	Filter          *uint16
	CustomFilter    *uint16
	MaxCustomFilter uint32
	FilterIndex     uint32
	File            *uint16
	MaxFile         uint32
	FileTitle       *uint16
	MaxFileTitle    uint32
	InitialDir      *uint16
	Title           *uint16
	Flags           uint32
	FileOffset      uint16
	FileExtension   uint16
	DefaultExt      *uint16
	CustomData      uintptr
	Hook            uintptr
	TemplateName    *uint16
	Reserved        unsafe.Pointer
	ReservedSize    uint32
	FlagsEx         uint32
}

const (
	ofnNoChangeDir   = 0x00000008
	ofnPathMustExist = 0x00000800
	ofnFileMustExist = 0x00001000
	ofnExplorer      = 0x00080000
)

func pickConfigFile() (string, error) {
	const maxPathCharacters = 32768
	file := make([]uint16, maxPathCharacters)
	filter := utf16.Encode([]rune(
		"Clash / mihomo YAML\x00*.yaml;*.yml\x00All files\x00*.*\x00\x00",
	))
	title, _ := windows.UTF16PtrFromString("Import Clash / mihomo profile")
	defaultExtension, _ := windows.UTF16PtrFromString("yaml")
	options := openFileNameW{
		StructSize:  uint32(unsafe.Sizeof(openFileNameW{})),
		Filter:      &filter[0],
		FilterIndex: 1,
		File:        &file[0],
		MaxFile:     maxPathCharacters,
		Title:       title,
		Flags: ofnExplorer | ofnFileMustExist | ofnPathMustExist |
			ofnNoChangeDir,
		DefaultExt: defaultExtension,
	}
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	result, _, _ := procGetOpenFileNameW.Call(
		uintptr(unsafe.Pointer(&options)),
	)
	if result != 0 {
		return windows.UTF16ToString(file), nil
	}
	extended, _, _ := procCommDlgExtendedErrorW.Call()
	if extended == 0 {
		return "", nil
	}
	return "", errors.New("file dialog failed")
}

func blob(value []byte) windows.DataBlob {
	if len(value) == 0 {
		return windows.DataBlob{}
	}
	return windows.DataBlob{Size: uint32(len(value)), Data: &value[0]}
}

func protectData(value []byte) ([]byte, error) {
	input := blob(value)
	entropy := blob(dpapiEntropy)
	var output windows.DataBlob
	if err := windows.CryptProtectData(
		&input,
		nil,
		&entropy,
		0,
		nil,
		windows.CRYPTPROTECT_UI_FORBIDDEN,
		&output,
	); err != nil {
		return nil, err
	}
	defer windows.LocalFree(windows.Handle(unsafe.Pointer(output.Data)))
	return append([]byte(nil), unsafe.Slice(output.Data, int(output.Size))...), nil
}

func unprotectData(value []byte) ([]byte, error) {
	input := blob(value)
	entropy := blob(dpapiEntropy)
	var output windows.DataBlob
	if err := windows.CryptUnprotectData(
		&input,
		nil,
		&entropy,
		0,
		nil,
		windows.CRYPTPROTECT_UI_FORBIDDEN,
		&output,
	); err != nil {
		return nil, err
	}
	defer windows.LocalFree(windows.Handle(unsafe.Pointer(output.Data)))
	return append([]byte(nil), unsafe.Slice(output.Data, int(output.Size))...), nil
}

func dataResult(data string, err error) string {
	if err != nil {
		return `{"ok":false,"error":"secure storage unavailable"}`
	}
	encoded, _ := json.Marshal(map[string]any{"ok": true, "data": data})
	return string(encoded)
}

func subscriptionHWID() (string, error) {
	key, err := registry.OpenKey(
		registry.LOCAL_MACHINE,
		`SOFTWARE\Microsoft\Cryptography`,
		registry.QUERY_VALUE,
	)
	if err != nil {
		return "", err
	}
	defer key.Close()
	machineGUID, _, err := key.GetStringValue("MachineGuid")
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(
		[]byte("Nozelt subscription HWID v1\x00" + strings.ToLower(machineGUID)),
	)
	// Present the app-scoped digest as a conventional UUID. The source
	// MachineGuid never leaves this process.
	sum[6] = (sum[6] & 0x0f) | 0x50
	sum[8] = (sum[8] & 0x3f) | 0x80
	return fmt.Sprintf(
		"%x-%x-%x-%x-%x",
		sum[0:4], sum[4:6], sum[6:8], sum[8:10], sum[10:16],
	), nil
}

//export NozeltFree
func NozeltFree(value unsafe.Pointer) {
	C.free(value)
}

//export NozeltGetSubscriptionHwid
func NozeltGetSubscriptionHwid() *C.char {
	value, err := subscriptionHWID()
	return cString(dataResult(value, err))
}

//export NozeltStart
func NozeltStart(config *C.char) *C.char {
	return cString(resultJSON(desktopRuntime.start(
		runtimeMihomo,
		C.GoString(config),
	)))
}

//export NozeltStartCore
func NozeltStartCore(coreName, config *C.char) *C.char {
	return cString(resultJSON(desktopRuntime.start(
		C.GoString(coreName),
		C.GoString(config),
	)))
}

//export NozeltValidateCoreConfig
func NozeltValidateCoreConfig(coreName, config *C.char) *C.char {
	kind, document := C.GoString(coreName), C.GoString(config)
	frontend, err := windowsFrontend(kind, document)
	if err != nil {
		return cString(resultJSON(err))
	}
	if err = validateWindowsFrontend(frontend); err != nil {
		return cString(resultJSON(err))
	}
	encoded, _ := json.Marshal(frontend)
	if err = core.ValidateConfig(string(encoded)); err != nil {
		return cString(resultJSON(err))
	}
	if kind == runtimeMihomo {
		return cString(resultJSON(nil))
	}
	if kind != runtimeXray && kind != runtimeSingBox {
		return cString(resultJSON(errors.New("unsupported core")))
	}
	relay, err := decodeRelay(document)
	if err != nil {
		return cString(resultJSON(err))
	}
	transport, err := relay.renderTransport(kind)
	if err != nil {
		return cString(resultJSON(err))
	}
	path, err := os.Executable()
	if err != nil {
		return cString(resultJSON(err))
	}
	directory := nativeCoreDirectory(path)
	name := "xray.exe"
	if kind == runtimeSingBox {
		name = "singbox-runner.exe"
	}
	return cString(resultJSON(validateExternalConfig(kind, filepath.Join(directory, name), directory, transport)))
}

//export NozeltStop
func NozeltStop() *C.char {
	return cString(resultJSON(desktopRuntime.stop()))
}

//export NozeltStopForRestart
func NozeltStopForRestart() *C.char {
	return cString(resultJSON(desktopRuntime.stopMode(true)))
}

//export NozeltUpdateGeoData
func NozeltUpdateGeoData() *C.char {
	return cString(resultJSON(updater.UpdateGeoDatabases()))
}

//export NozeltReload
func NozeltReload(config *C.char) *C.char {
	return cString(resultJSON(desktopRuntime.reload(C.GoString(config))))
}

//export NozeltSelectProxy
func NozeltSelectProxy(group, proxy *C.char) *C.char {
	if !desktopRuntime.isMihomo() {
		return cString(resultJSON(errors.New("selector unavailable")))
	}
	return cString(resultJSON(core.SelectProxy(C.GoString(group), C.GoString(proxy))))
}

//export NozeltGetStatus
func NozeltGetStatus() *C.char { return cString(desktopRuntime.statusJSON()) }

//export NozeltGetTraffic
func NozeltGetTraffic() *C.char { return cString(desktopRuntime.trafficJSON()) }

//export NozeltGetVersion
func NozeltGetVersion() *C.char {
	encoded, _ := json.Marshal(map[string]string{
		"nozeltCore": core.NozeltCoreVersion,
		"mihomo":     core.MihomoVersion(),
		"xray":       "26.9.30",
		"singBox":    "1.14.2",
	})
	return cString(string(encoded))
}

//export NozeltParseProxyLink
func NozeltParseProxyLink(value *C.char) *C.char {
	return cString(core.ParseProxyLink(C.GoString(value)))
}

//export NozeltParseSubscription
func NozeltParseSubscription(value *C.char) *C.char {
	return cString(core.ParseSubscription(C.GoString(value)))
}

//export NozeltTestProxyDelays
func NozeltTestProxyDelays(
	config, names, testURL *C.char,
	timeoutMs C.int,
	offline C.int,
) *C.char {
	if offline != 0 {
		return cString(core.TestProxyDelaysOffline(
			C.GoString(config),
			C.GoString(names),
			C.GoString(testURL),
			int(timeoutMs),
		))
	}
	return cString(core.TestProxyDelays(
		C.GoString(config),
		C.GoString(names),
		C.GoString(testURL),
		int(timeoutMs),
	))
}

//export NozeltTestNativeProxyDelays
func NozeltTestNativeProxyDelays(
	coreName, targets *C.char,
	timeoutMs C.int,
) *C.char {
	return cString(testExternalProxyDelays(
		C.GoString(coreName),
		C.GoString(targets),
		int(timeoutMs),
	))
}

//export NozeltBeginProxyDelays
func NozeltBeginProxyDelays(
	coreName, config, names, targets, testURL *C.char,
	timeoutMs C.int,
	offline C.int,
) *C.char {
	return cString(beginDesktopDelayJob(
		C.GoString(coreName),
		C.GoString(config),
		C.GoString(names),
		C.GoString(targets),
		C.GoString(testURL),
		int(timeoutMs),
		offline != 0,
	))
}

//export NozeltPollProxyDelays
func NozeltPollProxyDelays(jobID *C.char) *C.char {
	return cString(pollDesktopDelayJob(C.GoString(jobID)))
}

//export NozeltCancelDelayTests
func NozeltCancelDelayTests() {
	cancelDesktopDelayJobs()
}

//export NozeltGetConnections
func NozeltGetConnections() *C.char {
	if !desktopRuntime.isMihomo() {
		return cString(`[]`)
	}
	return cString(core.GetConnectionsJSON())
}

//export NozeltCloseConnection
func NozeltCloseConnection(id *C.char) C.int {
	if !desktopRuntime.isMihomo() {
		return 0
	}
	if core.CloseConnection(C.GoString(id)) {
		return 1
	}
	return 0
}

//export NozeltCloseAllConnections
func NozeltCloseAllConnections() C.int {
	if !desktopRuntime.isMihomo() {
		return 0
	}
	return C.int(core.CloseAllConnections())
}

//export NozeltGetLogs
func NozeltGetLogs() *C.char {
	desktopLogs.Lock()
	snapshot := append(
		make([]desktopLogEntry, 0, len(desktopLogs.entries)),
		desktopLogs.entries...,
	)
	desktopLogs.Unlock()
	encoded, err := json.Marshal(snapshot)
	if err != nil {
		return cString(`[]`)
	}
	return cString(string(encoded))
}

//export NozeltClearLogs
func NozeltClearLogs() {
	desktopLogs.Lock()
	desktopLogs.entries = desktopLogs.entries[:0]
	desktopLogs.Unlock()
}

//export NozeltProtectData
func NozeltProtectData(value *C.char) *C.char {
	protected, err := protectData([]byte(C.GoString(value)))
	if err != nil {
		return cString(dataResult("", err))
	}
	return cString(dataResult(base64.StdEncoding.EncodeToString(protected), nil))
}

//export NozeltUnprotectData
func NozeltUnprotectData(value *C.char) *C.char {
	protected, err := base64.StdEncoding.DecodeString(C.GoString(value))
	if err != nil {
		return cString(dataResult("", err))
	}
	plaintext, err := unprotectData(protected)
	if err != nil {
		return cString(dataResult("", err))
	}
	return cString(dataResult(string(plaintext), nil))
}

//export NozeltPickConfigFile
func NozeltPickConfigFile() *C.char {
	path, err := pickConfigFile()
	return cString(dataResult(path, err))
}
