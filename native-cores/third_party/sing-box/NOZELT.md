# Nozelt metadata extension

Source: Go module `github.com/sagernet/sing-box v1.14.2`, copied from the
checksum-verified Go module cache. Upstream GPL-3.0-or-later license is retained.

Local changes are limited to `adapter/router.go` and `route/rule/rule_set.go`:
an additional metadata flag identifies source IP/port predicates in decoded
JSON/SRS, including nested rules. The Windows runner rejects that flag and
process metadata before a downloaded update is committed, because an internal
SOCKS relay cannot reproduce the original source socket/application identity.
The Android runner adds no guard and retains upstream matching behavior.

Use this checked-in source through the runner's local module replacement.
