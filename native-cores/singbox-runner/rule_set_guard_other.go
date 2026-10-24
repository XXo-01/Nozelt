//go:build !windows

package main

import (
	"context"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
)

func installRuleSetGuard(context.Context, option.Options, adapter.Router) error { return nil }
