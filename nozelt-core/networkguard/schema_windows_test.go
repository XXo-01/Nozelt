//go:build windows

package networkguard

import (
	"github.com/tailscale/wf"
	"golang.org/x/sys/windows"
	"reflect"
	"testing"
)

// Reads Windows' real layer schemas. No provider/filter/route is created.
func TestWindowsWFPLayerSchemasReadOnly(t *testing.T) {
	if !windows.GetCurrentProcessToken().IsElevated() {
		t.Skip("WFP schema query requires administrator; no elevation/mutations in host tests")
	}
	s, err := wf.New(&wf.Options{Name: "Nozelt read-only schema check", Dynamic: true})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	layers, err := s.Layers()
	if err != nil {
		t.Fatal(err)
	}
	byID := map[wf.LayerID]*wf.Layer{}
	for _, layer := range layers {
		byID[layer.ID] = layer
	}
	for _, rule := range policy([]string{"fixture"}, 42, true, "svchost", 54321) {
		layer := byID[rule.Layer]
		if layer == nil {
			t.Fatal("missing WFP layer")
		}
		fields := map[wf.FieldID]reflect.Type{}
		for _, field := range layer.Fields {
			fields[field.ID] = field.Type
		}
		for _, condition := range rule.Conditions {
			if fields[condition.Field] == nil {
				t.Fatalf("WFP field %s absent at %s", condition.Field, rule.Layer)
			}
		}
	}
}
