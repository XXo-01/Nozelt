# nozelt-core

Go module that wraps the [mihomo](https://github.com/metacubex/mihomo) proxy
engine and exposes a narrow API to Android (Kotlin) via `gomobile bind`. It
is the proxy core of the Nozelt VPN client; the Flutter UI talks to Kotlin
via `MethodChannel`, and Kotlin talks to this module via the generated `.aar`.

On Windows, `windowsdll/` exposes the FFI ABI and shares one Mihomo/Wintun
frontend with contained Xray/sing-box transports. `networkguard/` owns persistent
WFP filters. See [the Windows security audit](../nozelt-app/WINDOWS_SECURITY_AUDIT.md)
for the policy, recovery and limits of the current verification.

For design, file layout, public API, and data flow see
[`ARCHITECTURE.md`](./ARCHITECTURE.md). Keep that document in sync with the
code — it is the source of truth for how this module is meant to be used.

## Build

Prerequisites: the Go 1.26.8 toolchain selected by `go.mod`, gomobile/gobind at
the `golang.org/x/mobile` revision pinned in `go.mod`, and Android NDK (path in
`ANDROID_NDK_HOME`).

```sh
# bash / WSL / Git Bash
./scripts/build_aar.sh            # release
./scripts/build_aar.sh --debug    # debug build with symbols
```

```powershell
# PowerShell on Windows
.\scripts\build_aar.ps1           # release
.\scripts\build_aar.ps1 -DebugBuild # debug build with symbols
```

Output: `build/nozelt.aar` (plus a `*-sources.jar` next to it).

Before shipping a dependency update, run `go test ./...`,
`go test -race ./core`, and `govulncheck ./...`.
