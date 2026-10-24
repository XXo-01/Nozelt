package core

import (
	"errors"
	"fmt"
	"strings"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/nozelt/nozelt-core/logger"
)

// SelectProxy changes a live mihomo selector for new connections without
// reloading the TUN or interrupting unrelated transports.
func SelectProxy(groupName, proxyName string) error {
	groupName = strings.TrimSpace(groupName)
	proxyName = strings.TrimSpace(proxyName)
	if groupName == "" || proxyName == "" {
		return errors.New("nozelt core: selector and proxy names are required")
	}

	current.mu.Lock()
	defer current.mu.Unlock()
	if !current.running {
		return ErrNotRunning
	}

	if err := setProxySelection(groupName, proxyName); err != nil {
		return fmt.Errorf("nozelt core: select proxy: %w", err)
	}
	if current.selections == nil {
		current.selections = make(map[string]string)
	}
	current.selections[groupName] = proxyName
	logger.Info("nozelt core: live proxy selection updated")
	return nil
}

func setProxySelection(groupName, proxyName string) error {
	proxy, ok := tunnel.Proxies()[groupName]
	if !ok {
		return fmt.Errorf("selector does not exist")
	}
	selector, ok := proxy.Adapter().(outboundgroup.SelectAble)
	if !ok {
		return fmt.Errorf("proxy is not a selector")
	}
	if err := selector.Set(proxyName); err != nil {
		// Upstream errors can quote a user-controlled proxy name. Collapse the
		// detail before it crosses the gomobile boundary.
		return fmt.Errorf("selection is unavailable")
	}
	return nil
}

// restoreSelectionsLocked reapplies the last explicit choices after mihomo
// replaces proxy adapters during a network recovery or config reload. Caller
// holds current.mu. Missing nodes are ignored and the new selector default is
// captured immediately afterwards.
func (s *state) restoreSelectionsLocked() {
	for groupName, proxyName := range s.selections {
		_ = setProxySelection(groupName, proxyName)
	}
}

// captureSelectionsLocked records the actual defaults of all selectors,
// including the initial selection encoded by ConfigBuilder. Caller holds
// current.mu. Names remain memory-only and are never included in diagnostics.
func (s *state) captureSelectionsLocked() {
	captured := make(map[string]string)
	for name, proxy := range tunnel.Proxies() {
		selector, ok := proxy.Adapter().(interface{ Now() string })
		if !ok {
			continue
		}
		if selected := selector.Now(); selected != "" {
			captured[name] = selected
		}
	}
	s.selections = captured
}
