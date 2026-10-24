//go:build windows

// Copyright 2026 Nozelt contributors. BSD-3-Clause, see LICENSE.
package wf

import (
	"golang.org/x/sys/windows"
	"unsafe"
)

// RulesForProviderLayers reads only the requested owner's rules. Parsing
// unrelated drivers' filter payloads is unnecessary and may be unsupported.
func (s *Session) RulesForProviderLayers(provider ProviderID, layers ...LayerID) ([]*Rule, error) {
	var result []*Rule
	for _, layer := range layers {
		var a arena
		template := (*fwpmFilterEnumTemplate0)(a.Alloc(unsafe.Sizeof(fwpmFilterEnumTemplate0{})))
		*template = fwpmFilterEnumTemplate0{ProviderKey: (*ProviderID)(unsafe.Pointer(toGUID(&a, windows.GUID(provider)))), LayerKey: windows.GUID(layer), ActionMask: 0xffffffff, Flags: 16}
		var handle windows.Handle
		err := fwpmFilterCreateEnumHandle0(s.handle, template, &handle)
		a.Dispose()
		if err != nil {
			return nil, err
		}
		for {
			page, pageErr := s.getRulePage(handle)
			if pageErr != nil {
				fwpmFilterDestroyEnumHandle0(s.handle, handle)
				return nil, pageErr
			}
			if len(page) == 0 {
				break
			}
			result = append(result, page...)
		}
		fwpmFilterDestroyEnumHandle0(s.handle, handle)
	}
	return result, nil
}
