package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json"
)

func main() {
	checkOnly := false
	configArgument := ""
	switch {
	case len(os.Args) == 2:
		configArgument = os.Args[1]
	case len(os.Args) == 3 && os.Args[1] == "--check":
		checkOnly = true
		configArgument = os.Args[2]
	default:
		fatalf("usage: singbox-runner [--check] <config.json|->")
	}
	var (
		content []byte
		err     error
	)
	if configArgument == "-" {
		content, err = io.ReadAll(os.Stdin)
	} else {
		content, err = os.ReadFile(configArgument)
	}
	if err != nil {
		fatalf("read config: %v", err)
	}

	ctx := include.Context(context.Background())
	if err = registerPlatform(ctx); err != nil {
		fatalf("register platform: %v", err)
	}
	options, err := json.UnmarshalExtendedContext[option.Options](ctx, content)
	if err != nil {
		fatalf("decode config: %v", err)
	}
	instance, err := box.New(box.Options{Context: ctx, Options: options})
	if err != nil {
		fatalf("create sing-box: %v", err)
	}
	if err = installRuleSetGuard(ctx, options, instance.Router()); err != nil {
		_ = instance.Close()
		fatalf("validate Windows rule sets: %v", err)
	}
	if checkOnly {
		if err = instance.Close(); err != nil {
			fatalf("close sing-box check: %v", err)
		}
		return
	}
	if err = instance.Start(); err != nil {
		_ = instance.Close()
		fatalf("start sing-box: %v", err)
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop
	signal.Stop(stop)
	if err = instance.Close(); err != nil {
		fatalf("stop sing-box: %v", err)
	}
}

func fatalf(format string, arguments ...any) {
	_, _ = fmt.Fprintf(
		os.Stderr,
		"Nozelt sing-box: "+format+"\n",
		arguments...,
	)
	os.Exit(1)
}
