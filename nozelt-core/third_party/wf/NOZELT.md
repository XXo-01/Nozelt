# Local WFP binding

Source: tailscale/wf commit 6fbb0a674ee6 (2024-02-14), BSD-3-Clause.
Runtime source files copied unchanged; generators, examples and upstream tests
are excluded. Nozelt adds `transaction_windows.go`, exposing the existing
native transaction calls, and `provider_rules_windows.go`, restricting reads
to our provider's layers, so network protection can change atomically. This
avoids depending on undocumented struct layouts outside this binding.
