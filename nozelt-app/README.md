# nozelt-app

Flutter Android and Windows client for the Nozelt VPN. The Go proxy engine lives in
[`../nozelt-core`](../nozelt-core); this module is the user-facing
front-end and the Android/Win32 platform hosts.

## Windows

The desktop build contains three profile-selectable native cores: embedded
Mihomo 1.19.32, Xray 26.9.30, and sing-box 1.14.2. A common Mihomo/Wintun
layer owns Windows TUN, process routing, DNS and connection telemetry. Xray and
sing-box run as contained transport processes behind authenticated loopback SOCKS.
The notification-area host remains alive when the window is closed, reflects
the TUN state with connected/monochrome Nozelt icons, and can either show the
window or toggle TUN on a single click.

See [WINDOWS_PORTABLE.md](WINDOWS_PORTABLE.md) for features, architecture,
data locations, validation and the first-PC test checklist.
The Windows network hardening changes, recovery procedure and unverified system
tests are documented in [WINDOWS_SECURITY_AUDIT.md](WINDOWS_SECURITY_AUDIT.md).
Build and package a complete x64 release:

```powershell
.\scripts\build_windows_portable.ps1
```

The build fails if any native executable, Wintun, license, or Xray geodata is
missing, preventing an apparently successful but incomplete portable bundle.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the layered design, the
platform channel surface, the TUN fd hand-off, and the config/settings layer.

## Requirements

- **Flutter** ≥ 3.41 (Dart ≥ 3.11).
- **Android SDK** with build-tools matching `flutter.compileSdkVersion`.
- **Android NDK** matching `flutter.ndkVersion`.
- **`nozelt-core` built**: `../nozelt-core/build/nozelt.aar` must exist.
  Build it from the core repo first:

  ```sh
  cd ../nozelt-core
  ./scripts/build_aar.sh           # or .\scripts\build_aar.ps1 on Windows
  ```

## First-time setup

```sh
# 1. Copy the .aar into android/app/libs/ (the artifact is not committed).
./scripts/sync_aar.sh              # or .\scripts\sync_aar.ps1 on Windows

# 2. Fetch Dart dependencies.
flutter pub get

# 3. Generate the json_serializable code (fromJson/toJson on models).
dart run build_runner build
```

## Running

```sh
flutter run -d <android-device-id>
```

Tap the big "Connect" button on the home screen. The first time the system
will ask for VPN permission — accept. A real TUN interface is established and
all device traffic is routed through mihomo.

### What works

- **Profiles & subscriptions**: add proxy servers via a subscription URL
  (downloaded + auto-refreshed), pasted share links, or an imported Clash
  YAML file. Link/subscription parsing is delegated to mihomo's `convert`
  (vless+reality/xhttp, vmess, trojan, ss/ssr, tuic,
  hysteria2+gecko, anytls, …).
  Multiple encrypted profiles; one active; live explicit node selection and
  per-node/all-node HTTPS latency tests. Latency probes require an active VPN,
  preventing cold tests from resolving private proxy hosts via system DNS.
- Config-file import uses Android's scoped system document picker with a 16 MB
  streaming limit; Nozelt requests no broad storage permission and ships no
  third-party file-picker/MIME stack.
- Real **TUN** routing: `VpnService.establish()` → fd → `Binding.setTunFd` →
  mihomo sing-tun. The system VPN key icon appears.
- **Settings** (persisted): TUN stack (gVisor/system/mixed), MTU, fake-ip
  DNS, `dns-hijack`, and IPv6. Android-incompatible `auto-route` and
  `auto-detect-interface` are forced off; `VpnService` owns routing.
- **Per-app split tunneling**: "all / only / except" modes with an app
  picker. Nozelt stays protected; only mihomo's transport sockets bypass the
  TUN via `VpnService.protect(fd)`. If every package saved in an "only" list
  has since been uninstalled, Nozelt safely falls back to tunnelling all apps
  instead of silently exposing the remaining apps.
- Every protected mihomo socket is also bound to the currently selected
  physical Android `Network`. A Wi-Fi/cellular handover therefore rebuilds HY2,
  QUIC, DNS, and TCP transports on the intended underlay instead of relying on
  a stale route; if the captured Network disappears during the bind, the socket
  stays protected and safely follows Android's new physical default.
- Connectivity callback debouncing is isolated from the serialized recovery
  loop: a late duplicate capabilities/link callback cannot cancel the retry
  sequence and strand a connected-looking tunnel after its first failed apply.
- Android per-UID blocked-network callbacks immediately withdraw an unusable
  underlay, keep the TUN fail closed, and select/recover through another
  validated Wi-Fi or cellular network when one is available.
- Global/rule routing plus validated domain, suffix, keyword, and CIDR rules;
  mode/rule edits hot-reload transactionally without recreating the TUN.
- Fake-IP DNS with IP-literal encrypted upstreams and no plaintext fallback.
  Synthetic ranges are constrained to safe subnets of `198.18.0.0/15`, and
  local/reverse names receive empty in-process answers instead of being sent
  to a public resolver.
- The native core independently rejects every TUN configuration that requests
  a local HTTP/SOCKS/mixed/redir/TProxy/DNS/controller/server/port-forward
  inbound. A damaged upper-layer config therefore fails closed instead of
  making Nozelt probeable through a loopback or LAN port.
- Mihomo's disk profile/fake-IP cache is forced off; selections are persisted
  by Nozelt and browsing metadata is not written to shared storage. A live
  selection survives network recovery and is written into the encrypted
  runtime generation for Always-on/process restoration.
- Rules-only hot reloads reuse live adapters; real proxy-definition changes
  close the old HY2/QUIC/TLS clients to prevent long-run FD/goroutine growth.
- Final stop closes tracked connections, proxy/rule providers, DNS and fake-IP
  memory, then clears mihomo's process-global config references. A technical
  fail-closed restart retains only the in-memory FakeDNS address mapping until
  its replacement starts, so applications cannot reconnect to an orphaned
  synthetic IP. A changed fake-IP range invalidates that mapping instead of
  cloning addresses outside the new pool; no browsing mapping is written to
  disk.
- A failed initial mihomo apply is rolled back completely, including partially
  published listeners, adapters, DNS objects, global rules and the detached
  TUN descriptor, before Android retries it.
- Wi-Fi/mobile underlay recovery, START_STICKY encrypted-state restoration,
  validated-network re-arming after an offline failed start, real
  status/traffic counters, and secret-free security/resource diagnostics.
- Once Android has established a requested TUN, even a first-start core error
  retains that interface as a fail-closed black hole through bounded retries.
  Traffic returns to the physical network only after an explicit disconnect
  (or system revocation), and the notification says that recovery is in
  progress rather than falsely claiming the proxy tunnel is already active.
- Full native restarts clear mihomo's stale TUN comparison state before a new
  Android fd is adopted. Reuse of the same numeric fd therefore cannot produce
  a false "connected" session with no packet listener.
- Subscription intervals are enforced after the VPN becomes connected, on
  foreground resume, and during long foreground sessions; automatic refresh
  never contacts a provider from the clear underlay, and overlapping triggers
  share one refresh operation. Manual first-profile/update actions remain
  available while disconnected.
- Imports are bounded to 16 MiB and 4096 proxies. Profile config/profile JSON
  work and subscription-envelope decoding run off Flutter's UI isolate, proxy
  and profile display names are bounded, and all-node latency tests use a
  fixed eight-worker pool rather than one goroutine per node. Periodic latency
  is volatile UI telemetry and does not force a full encrypted-profile rewrite
  every minute.
- Android Always-on VPN and lockdown integration, including system-start/
  post-unlock restoration, foreground recovery after OEM eviction, and an
  in-app guard against accidentally stopping Always-on.
- Android Recents shows the last rendered Nozelt page, matching ordinary
  application cards instead of replacing the preview with a black surface.
- RU/EN localization. Profiles, the active runtime config, DNS/domain rules,
  and per-app selections use Keystore-backed AES-256-GCM on Android; legacy
  plaintext routing settings are migrated and removed on first launch.
- Cross-provider sensitive-setting writes commit only after the encrypted
  atomic file succeeds. A failed MTU/DNS write cannot be carried into storage
  later by an otherwise successful per-app routing edit, or vice versa.

### Notes

- Missing/empty/unreadable profiles fail closed; a VPN config can never
  silently degrade to DIRECT.
- The `PROXY` selector contains only imported nodes—there is no hidden
  `DIRECT` member or automatic fallback.
- Imported Clash pseudo-outbounds such as `direct`/`pass`/`reject` cannot become
  selectable nodes; import and config generation both fail closed against an
  underlay-bypass entry. The normalized DTO endpoint must also match mihomo's
  raw map, so a disguised or mutated pseudo-node is rejected.
- Default rule routing blocks RFC1918, CGNAT, link-local, ULA,
  multicast/broadcast exposure, keeps loopback direct, and sends everything
  else to PROXY. LAN access is explicit opt-in.
- Optional domain detection reads only HTTP Host, TLS SNI, and QUIC Initial
  metadata inside mihomo, extending domain rules to apps that use their own
  DNS or connect by IP. It is disabled by default and sends no metadata out.
- Changing TUN stack/MTU, IPv6, DNS, or per-app routing automatically performs
  one serialized fail-closed TUN replacement while connected. Rule-only edits
  continue to hot-reload without replacing the Android VPN interface.
- Engine configuration reads split policy as independent state; the split
  notifier no longer watches back into the engine provider. A deferred
  post-connect event schedules any pending Builder update, avoiding the
  Riverpod dependency cycle that could abort connect before native start.
- A failed TUN-setting replacement is no longer reported as applied: its error
  propagates to the transaction owner, the previous encrypted setting is
  restored, and Nozelt performs a second keeper-backed restart from that known
  configuration. If recovery also fails, the retained TUN remains fail closed.
- Per-app routing uses the same transaction boundary. Nozelt tracks the exact
  policy accepted by the live Android Builder; a failed replacement restores
  that policy in encrypted storage and automatically rebuilds its TUN instead
  of leaving new checkboxes attached to an old interface.
- Every hot reload and full replacement shares one process-wide Dart queue.
  Concurrent MTU, routing, profile, subscription, and per-app edits therefore
  render the latest complete state and can never overlap two service
  generations or mistake another operation's generation for their own.
- Switching the active profile or refreshing its subscription uses the same
  fail-closed replacement; automatic maintenance never disconnects first and
  cannot create a clear-underlay window on devices without system lockdown.
  If that replacement fails, the exact previous profile snapshot is restored
  to encrypted storage and rebuilt through the retained TUN keeper. Failed
  subscription data therefore cannot become the next-start configuration.
- Android and other apps can detect the system VPN transport. Nozelt removes
  avoidable side channels (local proxy ports, UID-wide bypass, plaintext DNS)
  but does not claim to hide the OS-visible fact that a VPN is active.
- Android 13+ asks for notification permission once, in the explicit connect
  flow. Declining does not block VPN startup; accepting keeps the ongoing
  disconnect/status notification visible. Its locale updates immediately and
  its status-bar icon uses the dedicated monochrome brand asset.
- Flutter state uses Riverpod 3.3.2 lifecycle guards. Status restoration,
  profile maintenance, GeoIP, per-app apply timers, and preference queues stop
  touching state after their owning scope is destroyed, preventing late
  background callbacks from crashing a recreated Activity.
- A full live replacement keeps the last known-good rendered config encrypted
  until the new native core actually starts. If Flutter disappears during a
  failed MTU/profile/routing replacement, the foreground service rolls back
  that pending generation itself after bounded retries; stale delayed rollback
  jobs cannot overwrite a newer successful configuration. The matching old
  Profiles/TUN/per-app snapshot is stored in a separate AES-GCM crash journal.
  After a native fallback, startup restores that snapshot before creating
  Riverpod providers; a pending native decision is awaited and a successfully
  applied candidate deletes the journal. This keeps encrypted storage, UI,
  Android's TUN policy, and the live mihomo config on the same generation even
  when the Activity is killed in the middle of a replacement.

See [`ARCHITECTURE.md § 7`](ARCHITECTURE.md#7-known-limitations-and-todo)
for the full TODO list.

## Refreshing the engine

After any change to `nozelt-core`:

```sh
cd ../nozelt-core && ./scripts/build_aar.sh
cd ../nozelt-app  && ./scripts/sync_aar.sh
flutter run                  # hot restart is enough; no `pub get` needed
```

## Building Android APKs

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_android_apks.ps1 debug
```

This produces separate `app-arm64-v8a-debug.apk` and
`app-armeabi-v7a-debug.apk` files under `build/app/outputs/flutter-apk/`.
The explicit target list is required because the embedded Go AAR is ARM-only;
the helper prevents Flutter from expecting or publishing an unsafe x86 split.
Use `release` instead of `debug` only after configuring a private signing key;
the repository intentionally produces unsigned release artifacts.

## Linting

```sh
flutter analyze
```
