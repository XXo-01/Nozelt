// Copyright 2026 Nozelt contributors. BSD-3-Clause, see LICENSE.
//go:build windows

package wf

// Transaction commits all changes atomically; a failure or panic aborts them.
// Do not call Close or recursively open a transaction from fn.
func (s *Session) Transaction(fn func() error) error {
	if err := fwpmTransactionBegin0(s.handle, 0); err != nil {
		return err
	}
	defer fwpmTransactionAbort0(s.handle)
	if err := fn(); err != nil {
		return err
	}
	return fwpmTransactionCommit0(s.handle)
}
