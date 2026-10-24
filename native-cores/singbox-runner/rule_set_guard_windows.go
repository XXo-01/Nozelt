//go:build windows

package main

import (
	"context"
	"errors"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/service"
)

// The SOCKS transport cannot recover the originating application. Check the
// decoded metadata on initial download AND before every remote-set update is
// committed. Keep the DNS router's existing validations through delegation.
type windowsRuleSetGuard struct {
	previous adapter.DNSRuleSetUpdateValidator
}

func (g *windowsRuleSetGuard) ValidateRuleSetMetadataUpdate(tag string, metadata adapter.RuleSetMetadata) error {
	if metadata.ContainsProcessRule || metadata.ContainsSourceRule {
		return errors.New("provider process rules must use Nozelt routing")
	}
	if g.previous != nil {
		return g.previous.ValidateRuleSetMetadataUpdate(tag, metadata)
	}
	return nil
}

func installRuleSetGuard(ctx context.Context, options option.Options, router adapter.Router) error {
	guard := &windowsRuleSetGuard{previous: service.FromContext[adapter.DNSRuleSetUpdateValidator](ctx)}
	if options.Route != nil {
		for _, set := range options.Route.RuleSet {
			for _, tag := range set.Tag {
				if loaded, exists := router.RuleSet(tag); exists {
					if err := guard.ValidateRuleSetMetadataUpdate(tag, loaded.Metadata()); err != nil {
						return err
					}
				}
			}
		}
	}
	service.MustRegister[adapter.DNSRuleSetUpdateValidator](ctx, guard)
	return nil
}
