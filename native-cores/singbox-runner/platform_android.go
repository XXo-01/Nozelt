//go:build android

package main

import (
	"context"
	"errors"
	"fmt"
	"net/netip"
	"os"

	"github.com/nozelt/singbox-runner/internal/tunfd"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
	tun "github.com/sagernet/sing-tun"
	"github.com/sagernet/sing/common/logger"
	"github.com/sagernet/sing/service"
	"golang.org/x/sys/unix"
)

const tunFDEnvironment = "NOZELT_TUN_FD"

type androidPlatform struct {
	tunFD int
}

func registerPlatform(ctx context.Context) error {
	tunFD, hasTun, err := tunfd.Parse(os.Getenv(tunFDEnvironment))
	if err != nil {
		return fmt.Errorf("%s is invalid: %w", tunFDEnvironment, err)
	}
	if hasTun {
		service.MustRegister[adapter.PlatformInterface](
			ctx,
			&androidPlatform{tunFD: tunFD},
		)
	}
	return nil
}

func (p *androidPlatform) Initialize(adapter.NetworkManager) error { return nil }
func (p *androidPlatform) UsePlatformAutoDetectInterfaceControl() bool {
	return false
}
func (p *androidPlatform) AutoDetectInterfaceControl(int) error { return nil }
func (p *androidPlatform) UsePlatformInterface() bool           { return true }
func (p *androidPlatform) OpenInterface(
	options *tun.Options,
	_ option.TunPlatformOptions,
) (tun.Tun, error) {
	if p.tunFD < 3 {
		return nil, fmt.Errorf("invalid inherited TUN descriptor %d", p.tunFD)
	}
	duplicatedFD, err := unix.Dup(p.tunFD)
	if err != nil {
		return nil, fmt.Errorf("duplicate inherited TUN descriptor: %w", err)
	}
	options.FileDescriptor = duplicatedFD
	if options.Name == "" {
		options.Name = "tun0"
	}
	tunnel, err := tun.New(*options)
	if err != nil {
		_ = unix.Close(duplicatedFD)
		return nil, err
	}
	return tunnel, nil
}
func (p *androidPlatform) ProcessPlatformOptions(option.TunPlatformOptions) error {
	return nil
}
func (p *androidPlatform) UsePlatformDefaultInterfaceMonitor() bool {
	return false
}
func (p *androidPlatform) CreateDefaultInterfaceMonitor(
	logger.Logger,
) tun.DefaultInterfaceMonitor {
	return nil
}
func (p *androidPlatform) UsePlatformNetworkInterfaces() bool { return false }
func (p *androidPlatform) NetworkInterfaces() (
	[]adapter.NetworkInterface,
	error,
) {
	return nil, nil
}
func (p *androidPlatform) UnderNetworkExtension() bool { return false }
func (p *androidPlatform) NetworkExtensionIncludeAllNetworks() bool {
	return false
}
func (p *androidPlatform) ClearDNSCache() {}
func (p *androidPlatform) RequestPermissionForWIFIState() error {
	return nil
}
func (p *androidPlatform) ReadWIFIState(context.Context) adapter.WIFIState {
	return adapter.WIFIState{}
}
func (p *androidPlatform) SystemCertificates() []string { return nil }
func (p *androidPlatform) UsePlatformConnectionOwnerFinder() bool {
	return false
}
func (p *androidPlatform) FindConnectionOwner(
	*adapter.FindConnectionOwnerRequest,
) (*adapter.ConnectionOwner, error) {
	return nil, errors.New("connection owner lookup is unavailable")
}
func (p *androidPlatform) UsePlatformWIFIMonitor() bool  { return false }
func (p *androidPlatform) UsePlatformNotification() bool { return false }
func (p *androidPlatform) SendNotification(*adapter.Notification) error {
	return nil
}
func (p *androidPlatform) CancelNotification(string, int32) error { return nil }
func (p *androidPlatform) MyInterfaceAddress() []netip.Addr { return nil }
func (p *androidPlatform) UsePlatformNeighborResolver() bool { return false }
func (p *androidPlatform) StartNeighborMonitor(adapter.NeighborUpdateListener) error {
	return errors.New("neighbor monitoring is unavailable")
}
func (p *androidPlatform) CloseNeighborMonitor(adapter.NeighborUpdateListener) error {
	return nil
}
func (p *androidPlatform) UsePlatformShell() bool { return false }
func (p *androidPlatform) CheckPlatformShell() error {
	return errors.New("platform shell is unavailable")
}
func (p *androidPlatform) OpenShellSession(
	*adapter.PlatformUser, string, []string, string, int32, int32,
) (adapter.ShellSession, error) {
	return nil, errors.New("platform shell is unavailable")
}
func (p *androidPlatform) LookupUser(string) (*adapter.PlatformUser, error) {
	return nil, errors.New("platform users are unavailable")
}
func (p *androidPlatform) LookupSFTPServer() (string, error) {
	return "", errors.New("SFTP server is unavailable")
}
func (p *androidPlatform) ReadSystemSSHHostKey() ([]byte, error) {
	return nil, errors.New("system SSH host key is unavailable")
}
func (p *androidPlatform) TailscaleHostname() string { return "" }
func (p *androidPlatform) UsePlatformBridge() bool { return false }
func (p *androidPlatform) CreateBridge(adapter.BridgeOptions) (adapter.BridgeSession, error) {
	return nil, errors.New("platform bridge is unavailable")
}
