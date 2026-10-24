//go:build windows

package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/srs"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing-box/route/rule"
	"github.com/sagernet/sing/common/json"
	"github.com/sagernet/sing/common/logger"
	"github.com/sagernet/sing/service"
)

type rejectingDNSValidator struct{}

func (rejectingDNSValidator) ValidateRuleSetMetadataUpdate(string, adapter.RuleSetMetadata) error {
	return errors.New("original DNS validation")
}

func TestWindowsRuleSetGuardPreservesDNSValidation(t *testing.T) {
	guard := &windowsRuleSetGuard{previous: rejectingDNSValidator{}}
	if err := guard.ValidateRuleSetMetadataUpdate("test", adapter.RuleSetMetadata{}); err == nil || err.Error() != "original DNS validation" {
		t.Fatalf("underlying DNS validation lost: %v", err)
	}
}

// Exercise upstream parsing/metadata rather than hand-building the process
// flag. The same parser and validator are used for downloaded SRS/source sets.
func TestWindowsRuleSetGuardInspectsDecodedSourceAndBinary(t *testing.T) {
	for _, format := range []string{"source", "binary"} {
		for _, predicate := range []string{"domain", "process_name", "source_ip_cidr", "source_port"} {
			name := format + "/" + predicate
			content := []byte(`{"version":4,"rules":[{"domain":["example.test"]}]}`)
			if predicate != "domain" {
				value := `["steam.exe"]`
				if predicate == "source_ip_cidr" {
					value = `["127.0.0.0/8"]`
				}
				if predicate == "source_port" {
					value = `[12345]`
				}
				content = []byte(`{"version":4,"rules":[{"type":"logical","mode":"or","rules":[{"` + predicate + `":` + value + `},{"domain":["example.test"]}]}]}`)
			}
			t.Run(name, func(t *testing.T) {
				if format == "binary" {
					compat, err := json.UnmarshalExtended[option.PlainRuleSetCompat](content)
					if err != nil {
						t.Fatal(err)
					}
					plain, err := compat.Upgrade()
					if err != nil {
						t.Fatal(err)
					}
					var encoded bytes.Buffer
					if err = srs.Write(&encoded, plain, 4); err != nil {
						t.Fatal(err)
					}
					content = encoded.Bytes()
				}
				path := filepath.Join(t.TempDir(), "rules")
				if err := os.WriteFile(path, content, 0600); err != nil {
					t.Fatal(err)
				}
				ctx := service.ContextWith[adapter.DNSRuleSetUpdateValidator](context.Background(), &windowsRuleSetGuard{})
				set, err := rule.NewLocalRuleSet(ctx, logger.NOP(), "test", option.RuleSet{
					Type: "local", Format: format, LocalOptions: option.LocalRuleSet{Path: path},
				})
				if set != nil {
					defer set.Close()
				}
				if predicate != "domain" {
					if err == nil || !strings.Contains(err.Error(), "provider process rules") {
						t.Fatalf("process set accepted: %v", err)
					}
				} else if err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
