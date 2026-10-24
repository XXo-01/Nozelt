# Nozelt native cores

Nozelt keeps Mihomo embedded through `nozelt.aar` on Android and
`nozelt_core.dll` on Windows. Xray and sing-box run behind a process boundary
and are started only when a profile selects that core.

The process boundary is intentional:

- every Go core has its own runtime and cannot collide with gomobile's
  process-global `go.Seq` classes;
- only one engine process is alive at a time;
- the Android VPN service owns the TUN interface and passes its descriptor to
  the selected engine;
- switching a profile stops the old core before the new one is started.
- Windows places every child core in a kill-on-close Job Object, validates a
  configuration before replacing the live process, and ships Wintun plus the
  pinned Xray geodata beside the portable executable.

Windows portable rebuild (2026-10-03): Xray `v26.9.30`, sing-box `v1.14.2`.
Windows uses a common Mihomo TUN/telemetry layer and authenticated loopback
SOCKS transports for these cores; only Android passes the platform TUN descriptor.
See `../nozelt-app/WINDOWS_PORTABLE.md` for the current Windows design and checks.

Windows security rebuild (2026-10-06): sing-box uses Go 1.26.8, x/crypto 0.56.0,
grpc 1.83.2, chi 5.3.0 and x/mod 0.40.0. Xray uses Go 1.27.1, compress 1.18.7
and fixed grpc commit `v1.85.0-dev.0.20260825072537-93e31b48545e`.
The build script pins these dependency overlays. See
`../nozelt-app/WINDOWS_SECURITY_AUDIT.md` for scan results and remaining tests.
The runner uses the checked-in sing-box v1.14.2 source in `third_party/sing-box`
with one source-predicate metadata extension. Windows validates process/source
metadata on initial rule-set load and before downloaded updates are committed;
the DNS validator remains active. The local source and modification are described
in `third_party/sing-box/NOZELT.md`.

Previously packaged Android upstream versions (Android binaries were not rebuilt):

- Xray-core `v26.9.9`;
- sing-box `v1.14.1`.

Rebuild both ARM targets from the pinned sources with:

```powershell
.\native-cores\build_android.ps1
```

The resulting PIE executables are stored under
`nozelt-app/android/app/src/main/jniLibs/<abi>/`. Android packages them as
native libraries so they remain executable under the app sandbox.

The pinned release's `geoip.dat` and `geosite.dat` live in
`android/app/src/main/assets/xray/`; the service installs them into private
storage on first Xray launch and sets `XRAY_LOCATION_ASSET`.

Build the Windows x64 executables and verified Wintun dependency with:

```powershell
.\native-cores\build_windows.ps1
```

The Windows sing-box build uses the same gVisor, QUIC, WireGuard, uTLS, and
Clash API feature tags as Android. Omitting these tags produces a binary that
can parse common profiles but fails when it creates their outbounds.
