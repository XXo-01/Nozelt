package tunfd

import "testing"

func TestParseAllowsNativeProbeWithoutTun(t *testing.T) {
	descriptor, present, err := Parse("")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if present || descriptor != 0 {
		t.Fatalf("unexpected descriptor state: descriptor=%d present=%v", descriptor, present)
	}
}

func TestParseAcceptsVpnDescriptor(t *testing.T) {
	descriptor, present, err := Parse("3")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !present || descriptor != 3 {
		t.Fatalf("unexpected descriptor state: descriptor=%d present=%v", descriptor, present)
	}
}

func TestParseRejectsInvalidValue(t *testing.T) {
	for _, value := range []string{"invalid", "-1", "0", "2"} {
		if _, _, err := Parse(value); err == nil {
			t.Fatalf("expected %q to be rejected", value)
		}
	}
}
