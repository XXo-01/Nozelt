//go:build windows

package networkguard

import (
	"os"
	"testing"

	"github.com/tailscale/wf"
	"golang.org/x/sys/windows"
)

// Never enable on the user's working computer. This test changes WFP policy
// briefly and requires a disposable Windows VM, without another VPN.
func TestIsolatedWFPPolicyRoundTripAndRollback(t *testing.T) {
	if os.Getenv("NOZELT_WFP_TEST_DISPOSABLE_VM") != "I_ACCEPT_TEMPORARY_NETWORK_BLOCK" {
		t.Skip("only allowed in explicitly selected disposable Windows VM")
	}
	if !windows.GetCurrentProcessToken().IsElevated() {
		t.Fatal("VM test requires administrator")
	}
	if err := CheckCompatibility(); err != nil {
		t.Fatal(err)
	}
	if protected, err := Protected(); err != nil || protected {
		t.Fatalf("VM must start without retained Nozelt protection: protected=%v err=%v", protected, err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	guard, err := Arm([]string{executable}, true)
	if err != nil {
		t.Fatal(err)
	}
	defer guard.Close()
	defer func() {
		if err := Release(); err != nil {
			t.Errorf("VM protection release failed: %v; run recovery script", err)
		}
	}()
	if protected, err := Protected(); err != nil || !protected {
		t.Fatalf("retained protection not detected: %v %v", protected, err)
	}
	rules, err := ownedRules(guard.session)
	if err != nil || len(rules) == 0 {
		t.Fatalf("native provider enumeration failed: %v", err)
	}
	before := len(rules)
	// An intentional duplicate key must abort the complete deletion transaction.
	err = guard.session.Transaction(func() error {
		if err := guard.session.DeleteRule(rules[0].ID); err != nil {
			return err
		}
		return guard.session.AddRule(rules[1])
	})
	if err == nil {
		t.Fatal("duplicate key accepted")
	}
	rules, err = ownedRules(guard.session)
	if err != nil || len(rules) != before {
		t.Fatalf("transaction failed to roll back: count=%d err=%v", len(rules), err)
	}
	if err := guard.ProtectRelay(54321); err != nil {
		t.Fatal(err)
	}
	for _, rule := range rules {
		if rule.Provider != provider || rule.Sublayer != sublayer || rule.Persistent || (rule.Action == wf.ActionBlock && !rule.HardAction) {
			t.Fatal("serialized native policy lost ownership or lifetime")
		}
	}
}
