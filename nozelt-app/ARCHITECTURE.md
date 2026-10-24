# nozelt-app architecture

> Living document. Update on every significant code change. If something here
> contradicts the code, the code wins — and this file is wrong and must be
> fixed.
>
> For the Go engine consumed by this app, see
> [`../nozelt-core/ARCHITECTURE.md`](../nozelt-core/ARCHITECTURE.md).

## 1. Overview

`nozelt-app` is the Flutter Android and Windows client of the Nozelt VPN. Android speaks to
the Go engine (`nozelt-core`) through a `.aar` produced by `gomobile bind`,
linked into the Android module and accessed from Kotlin via the
JNI glue gomobile generates.

Windows uses Dart FFI into `nozelt_core.dll` and a Win32 tray/window host.
The common Mihomo/Wintun frontend owns DNS, process routing and telemetry;
Xray/sing-box are authenticated loopback SOCKS transport children. WFP
protection lives in a dynamic session: it exists only while Nozelt is connected
and disappears on any disconnect, failed start, crash or kill.
See [WINDOWS_SECURITY_AUDIT.md](WINDOWS_SECURITY_AUDIT.md) for the lifecycle,
DNS/provider policy, recovery and the pending isolated system tests. The diagram
below describes the Android platform path.

The three layers stacked top-to-bottom:

```
Flutter (Dart)            lib/
   │  MethodChannel "engine"  ↓     EventChannel "traffic"  ↑     EventChannel "logs"  ↑
   ▼
Kotlin (Android)          android/app/src/main/kotlin/dev/nozelt/nozelt/
   ├─ MainActivity            registers channels, delegates to bridge
   ├─ NozeltVpnService        foreground service that owns the engine lifecycle
   ├─ EngineBridge            calls into Binding.*
   ├─ LoggerImpl              implements binding.Logger
   └─ TrafficStreamHandler    pure 1 Hz forwarder of Go-side traffic JSON
   │  JNI (gomobile-generated symbols in binding.*)
   ▼
Go (binding.Binding)      nozelt.aar (built from ../nozelt-core)
   └─ delegates to core.* which embeds mihomo (executor + listener + statistic)
```

### Iteration history

**Iteration 1 — wire-up skeleton.** End-to-end channel pipeline proven. The
Go side was a stub: `core.applyConfig` did nothing, no port opened, traffic
stats faked on the Kotlin side with a `synthetic: true` flag.

**Iteration 2 — real mihomo.** `nozelt-core` now actually runs mihomo:
`config.Parse → executor.ApplyConfig` opens the configured listeners, a
post-apply port sanity check turns silent bind failures into typed Start
errors, and `statistic.DefaultManager` feeds real traffic numbers. The
Kotlin synthetic generator is gone; `TrafficStreamHandler` is a pure
forwarder. mihomo's internal log stream is subscribed at Go init time and
flows through the existing `dev.nozelt.nozelt/logs` channel.

**Iteration 3 — real TUN, settings, split tunneling.** `NozeltVpnService`
now calls `VpnService.Builder.establish()`, detaches the fd, and hands it to
the Go engine via `Binding.setTunFd(fd)` before `start`. All device traffic
is routed through the tunnel. The mihomo YAML is no longer hardcoded — it is
assembled by `config_builder.dart` from persisted user settings (TUN stack,
MTU, fake-ip DNS, toggles) and per-app split-tunnel selections. See §§9–11.

**Current Android hardening.** Profiles and the active rendered config are
AES-256-GCM encrypted with a non-exportable Android Keystore key; config
secrets never travel in Intent extras. mihomo exposes no local proxy,
controller, or DNS listener. Its outbound TCP/UDP/QUIC sockets are excluded
individually with `VpnService.protect(fd)`, while Nozelt's UI/subscription
traffic stays inside the VPN. Network callbacks rebind the underlay and rebuild
stale HY2/QUIC transports after Wi-Fi/mobile handover. Domain/CIDR rules,
per-app split tunneling, fake-IP DNS, manual node selection/latency, encrypted
subscription downloads, RU/EN localization, and secret-free diagnostics are
implemented. The engine fails closed when profiles are unavailable or empty.

**Current Android presentation.** The mobile home screen keeps routing mode in
the former uptime card and renders live uptime inside the connection button.
Tapping that button while `EngineNotifier.connect()` is pending calls the normal
serialized stop path; the lifecycle epoch prevents the abandoned async connect
from publishing a later connected state. Mobile settings hide immutable DNS
interception and the always-enabled country-detection preference, move Android
Always-on/lockdown instructions to a dedicated back-navigable screen, and keep
profile management in the Proxies tab. The compact proxy list preserves its lazy
sliver implementation, indicates selected nodes/profiles with a leading accent
bar, and moves endpoint/transport/flow/obfuscation details into the node dialog.
Android Recents is allowed to snapshot the last rendered Flutter page. The
foreground notification uses the full-viewport shield-plus vector so its
status-bar/header glyph is not reduced by launcher-icon padding.

**22.10.2026 Android pass.** Android now uses the Windows visual design:
the ring power button, home cards shared through `ui/widgets/home_cards.dart`,
flag images instead of emoji, capsule buttons, round outlined icon buttons,
pill segmented controls and the subscription stat tiles (stacked on a phone).
Layout stays mobile: bottom navigation, 48 px touch targets, Roboto.
Connection fixes: ICMP to real IPs is answered inside the tunnel (mihomo would
otherwise forward it DIRECT, outside the proxy); the VPN declares
`setMetered(false)` so meteredness follows the underlay; failed-start retries
re-arm only on a real network change with a 1→30 min backoff; IPv6 address
flag/lifetime updates no longer trigger a full network recovery; a live reload
that would change TUN parameters is rejected in the core (needs a restart);
native-core latency probes use a random SOCKS account; the native spawner
prepares env/argv before `fork()`; traffic polling pauses while the Activity
is stopped; idle url-test groups are lazy with a 60 s default; GeoIP lookups
are skipped for Xray/sing-box, whose app traffic bypasses the VPN; Go has a
256 MiB soft memory limit and returns memory after Stop.

## 2. File layout

```
nozelt-app/
├── pubspec.yaml
├── ARCHITECTURE.md                  # this file
├── README.md                        # build & run quick-start
├── scripts/
│   ├── sync_aar.sh                  # bash:       copy ../nozelt-core/build/nozelt.aar
│   └── sync_aar.ps1                 # PowerShell: same
│
├── lib/
│   ├── main.dart                    # ProviderScope (+ SharedPreferences override) + theme
│   └── src/
│       ├── core/
│       │   ├── nozelt_engine.dart   # channel wrappers (+ apps, icons, parseProxyLink/Subscription)
│       │   ├── models.dart          # Status, Listeners, TunStatus, Traffic, LogEntry, ...
│       │   ├── models.g.dart        # generated (json_serializable)
│       │   ├── config_builder.dart  # assembles mihomo config (JSON) + tunOptions from settings+nodes
│       │   ├── tun_settings.dart    # TunSettings model (stack/mtu/dns/toggles) + validate
│       │   ├── split_tunnel_settings.dart # SplitMode + selected packages
│       │   ├── app_info.dart        # installed-app row (label/package/system)
│       │   ├── proxy_node.dart      # parsed node (name/type/server/port + raw mihomo map)
│       │   ├── profile.dart         # Profile + ProfileType + ProfilesState
│       │   └── subscription_client.dart # http download of subscription URLs (Dart only)
│       ├── data/
│       │   ├── profile_store.dart   # Android encrypted-profile channel + legacy migration
│       │   ├── secure_settings_store.dart # pre-frame Android secure-store migration
│       │   └── sensitive_settings_repository.dart # atomic TUN + split snapshot
│       ├── state/
│       │   ├── app_lifecycle_provider.dart # central foreground/background signal
│       │   ├── engine_provider.dart      # engine lifecycle + streams
│       │   ├── settings_provider.dart    # TunSettings over sensitive repository
│       │   ├── split_tunnel_provider.dart# split settings + installed apps + lazy icons
│       │   ├── profiles_provider.dart    # serialized profiles CRUD + subscription refresh
│       │   ├── network_settings_controller.dart # serialized full TUN replacement + rollback
│       │   └── routing_config_controller.dart # transactional live rule reload + rollback
│       └── ui/
│           ├── home_screen.dart          # lazy four-tab shell + deferred stale-refresh
│           ├── home_tab.dart             # connection, profile/node, traffic and latency
│           ├── proxies_tab.dart          # profile/node selection + latency tests
│           ├── routing_tab.dart          # global/rules + domain/CIDR editor + per-app routing
│           ├── settings_tab.dart         # language/privacy/TUN/DNS/about
│           ├── diagnostics_screen.dart   # aggregate secret-free security/resource state
│           ├── split_tunnel_screen.dart  # per-app picker (lazy icons, search)
│           ├── profiles_screen.dart      # profile list + activate/refresh/rename/delete
│           ├── add_profile_screen.dart   # subscription / links / file
│           └── widgets/                  # shared Nozelt controls/cards/navigation
│
└── android/
    └── app/
        ├── libs/
        │   └── nozelt.aar           # not committed — refresh via scripts/sync_aar.*
        ├── build.gradle.kts         # direct local AAR dependency, minSdk 24, targetSdk 36
        └── src/main/
            ├── AndroidManifest.xml  # permissions + NozeltVpnService registration
            └── kotlin/dev/nozelt/nozelt/
                ├── MainActivity.kt   # channels + getInstalledApps / getAppIcon
                ├── EngineBridge.kt   # encrypted runtime hand-off + native ABI calls
                ├── EncryptedFileStore.kt # Keystore AES-GCM + AtomicFile primitive
                ├── SecureProfileStore.kt / SecureRuntimeConfigStore.kt
                ├── SecureSettingsStore.kt # encrypted routing/DNS/app selections
                ├── VpnProcessLifecycle.kt # Activity/Service singleton lifecycle mutex
                ├── LoggerImpl.kt     # on-demand, redacted; logcat only in debug builds
                ├── NozeltVpnService.kt # VpnService.Builder + establish + fd hand-off
                └── TrafficStreamHandler.kt
```

## 3. Data flow: tapping "Connect"

1. **User taps `ConnectionButton`** in `home_screen.dart`. The button reads
   the current `EngineState` via Riverpod and calls
   `engineStateProvider.notifier.connect()`.
2. **`EngineNotifier.connect`** transitions UI state to `connecting` and
   asks the engine to **prepare the VPN permission**:
   `_engine.prepareVpn()` → `MethodChannel.invokeMethod('prepareVpn')`.
3. **Kotlin `MainActivity.handlePrepareVpn`** calls `VpnService.prepare(this)`.
   If permission is already granted (or unnecessary) it returns `true`
   immediately. Otherwise the system consent intent is launched via
   `startActivityForResult`; the pending `MethodChannel.Result` is held
   until `onActivityResult` resolves it.
4. **User accepts the system VPN dialog.** `onActivityResult` returns
   `RESULT_OK` → the pending `Result` resolves with `true`. (On `false`,
   the UI shows a SnackBar with the error message and parks at
   `EngineConnectionState.error`.)
5. **`EngineNotifier.connect`** validates encrypted profile availability, the
   non-empty active node list, and persisted `TunSettings` (MTU, fake-IP CIDR,
   IP-literal encrypted DNS, rules). If OK it builds the config with
   `ConfigBuilder.buildConfig(settings, nodes, selectedNodeName)` plus
   `ConfigBuilder.buildTunOptions(settings, splitMode, apps)`, then calls
   `_engine.start(config,
   tunOptionsJson: jsonEncode(tunOptions))`.
6. **Kotlin `EngineBridge.start`** writes the config and TUN options to
   Keystore-backed `SecureRuntimeConfigStore`, then dispatches an action-only
   `startForegroundService` Intent. No endpoint, key, password, or full config
   enters Intent history or diagnostic dumps. Each encrypted record has a
   random non-secret request ID; an old shutdown/failure may delete only its
   own generation, never a newer reconnect written by the Activity. Dispatch
   failure restores the prior encrypted generation transactionally.
7. **`NozeltVpnService.onStartCommand`** receives `ACTION_START`,
   enters foreground synchronously, decrypts the runtime record on an IO
   coroutine, builds a `VpnService.Builder`, and calls `establish()` →
   `ParcelFileDescriptor`. The service retains this original as a fail-closed
   TUN keeper and detaches a duplicate for Go.
8. **Anti-loop + fd hand-off**: the service first installs a gomobile callback
   backed by `VpnService.protect(fd)`, then calls `Binding.setTunFd(fd)` with
   the duplicate. Go exclusively owns that fd; Kotlin exclusively owns the
   keeper. Every later mihomo transport socket must be protected successfully
   or its dial fails closed.
9. **`EngineBridge.startEngineSync(config)`** → `binding.Binding.start(config)`.
10. **Go `core.Start`** parses the YAML, injects the fd into
    `cfg.General.Tun.FileDescriptor`, `executor.ApplyConfig`, then
    `verifyListeners` + `verifyTun` (`listener.GetTunConf().Enable`). sing-tun
    serves the tunnel on the fd.
11. **Back in the notifier**, `_awaitRunning()` polls bounded `getStatus()`
    calls for up to 16s until `running` is true (covering the async
    establish+start without an unbounded native wait), then the
    UI transitions to `connected` and a 1 Hz poller keeps status fresh.

The disconnect path is symmetric: notifier → MethodChannel `stop` →
service receives `ACTION_STOP` → `EngineBridge.stopEngineSync` →
`binding.Stop` → `executor.Shutdown` (closes the TUN listener and the fd) +
explicit `listener.ReCreate*(0, …)` → service tears down the notification and
deletes the runtime config. Only after Go transports drain is the socket
protector detached. Because mihomo's CLI-oriented `Shutdown` does not release
outbound clients/providers, the wrapper additionally closes every tracker,
proxy/rule provider, DNS/fake-IP cache, and clears process-global tunnel maps.
`onRevoke` routes through the same shutdown.

For physical-network changes, an explicit `NOT_VPN` callback selects a
validated Wi-Fi/mobile underlay, updates `setUnderlyingNetworks`, and debounces
`Binding.recoverNetwork()`. Recovery closes tracked connections and rebuilds
proxy/DNS adapters while retaining the TUN fd. Validation transitions and
same-network link-property changes (interface, addresses, DNS) also trigger
recovery, so DHCP/roaming changes are not missed merely because Android keeps
the same `Network` handle. An unvalidated Wi-Fi network never displaces a
validated cellular network. `onBlockedStatusChanged` also withdraws a physical
network that Android has blocked for Nozelt's UID and keeps the TUN fail closed
until another usable underlay is selected. Three failures escalate to a full
encrypted-state restart. Each recovery attempt takes the same process lifecycle mutex as
start/stop/reload, so a disconnect cannot race a stale recovery into restarting
the global core. `START_STICKY` can also restore after process/OEM service
recreation without putting secrets in an Intent.

The first `validated=true` callback also counts when the engine started on the
same still-captive/unvalidated network, so early HY2/QUIC sockets are rebuilt.
If bounded start retries were exhausted while offline, a later validated
physical network re-arms one retry sequence while the retained TUN remains a
fail-closed black hole. A registered `ACTION_USER_UNLOCKED` receiver similarly
re-arms a requested Always-on start after Android Keystore becomes available.
If a requested native session is still down when Flutter returns from a long
background pause, the foreground state restore dispatches one bounded rebuild
instead of retaining a stale connected/error snapshot. Concurrent startup,
resume, and OEM activity-recreation restore triggers are coalesced so they
cannot dispatch duplicate restarts against the process-global engine.

Repeated `ACTION_START` is coalesced only when its encrypted request ID equals
the live request ID. A genuinely newer generation drains/replaces the old Go
session under the process lifecycle mutex while Kotlin keeps the previous TUN
open, preventing a stale UI/native race from running one profile but persisting
another. Explicit proxy selection is also transactional: native code rewrites
the selected-first order in the encrypted runtime before calling
`Binding.selectProxy`, and restores the previous record if selection fails.
This preserves the chosen node across a service/process restart even when the
Flutter UI is not launched.

Full replacements use a two-generation encrypted runtime record. The proposed
config is staged with the exact last known-good config as its fallback; the
service clears that fallback only after `Binding.start` succeeds. Dart normally
owns transactional rollback, but if its Activity/isolate disappears during a
failed MTU/profile/routing replacement, Kotlin restores the fallback after the
bounded caller window and starts it through the retained TUN. Candidate
comparison makes delayed jobs conditional, so they cannot overwrite a later
replacement. An explicit Dart rollback to the stored fallback clears the
pending failed candidate instead of reversing the rollback on a second error.

Each replacement that follows a durable Profiles/TUN/per-app mutation also
stages the exact previous high-level snapshot in the separate AES-GCM
`vpn-rollback.enc` journal under its own Android Keystore key. A successful
candidate deletes it. Native fallback marks it rolled back only after the old
runtime generation is selected. Flutter bootstrap waits for any pending native
decision, restores a confirmed snapshot before `ProviderScope`, then
conditionally acknowledges its journal id. Interrupted writes are reconciled
against `vpn-runtime.enc`; foreground restore additionally compares the fully
rendered durable config/TUN options with native encrypted runtime and converges
them through the same fail-closed queue. Thus an Activity/process death cannot
leave old live routing paired with new durable UI state (or vice versa).

## 4. Platform channel surface

### Method channel — `dev.nozelt.nozelt/engine`

| Method      | Args                       | Result (success)         | Throws (`PlatformException` → `NozeltEngineException`) |
|-------------|----------------------------|--------------------------|--------------------------------------------------------|
| `start`     | `{ configYaml: String, tunOptionsJson?: String }` | `true`     | `bad_args`, `start_failed` |
| `stop`      | —                          | `true`                   | `stop_failed`                                           |
| `restart`   | —                          | `true`                   | `restart_failed`                                        |
| `restartWithConfig` | `{ configYaml, tunOptionsJson?, rollbackKind?, rollbackPayload? }` | successful start generation | `bad_args`, `restart_failed` |
| `reloadConfig` | `{ configYaml, tunOptionsJson?, rollbackKind?, rollbackPayload? }` | `true` | `bad_args`, `reload_failed` |
| `matchesRuntimeConfig` | `{ configYaml, tunOptionsJson? }` | `bool` | `bad_args`, `runtime_match_failed` |
| `isVpnRequested` | —                     | `bool` (lightweight; no Go load) | —                                                  |
| `isAlwaysOnVpn` | —                      | `bool` (lightweight policy state) | —                                                 |
| `getVpnPolicyState` | —                  | `{alwaysOn, lockdown, lockdownKnown}` | —                                             |
| `getStatus` | —                          | `String` (JSON `Status`) | `status_failed`                                         |
| `getVersion`| —                          | `String` (JSON `Versions`)| `version_failed`                                       |
| `prepareVpn`| —                          | `true` (granted) / `false`(denied) | `busy`, `prepare_failed`                       |
| `getInstalledApps` | —                   | `List<{packageName,label,system}>` | `apps_failed`                          |
| `getAppIcon`| `{ packageName: String }`  | `Uint8List` (96 px PNG) | `bad_args`, `icon_failed`                              |
| `pickConfigFile` | — | nullable `{name, bytes}` (max 16 MiB) | `busy`, `file_*` |
| `parseProxyLink` | `{ link: String }`    | `String` (JSON `{ok,proxy}`) | `bad_args`, `parse_failed`                       |
| `parseSubscription` | `{ content: String }` | `String` (JSON `{ok,proxies,count}`) | `bad_args`, `parse_failed`                |
| `testProxyDelays` | `{ configYaml, namesJson, testUrl, timeoutMs }` | JSON delay envelope | `delay_test_failed` |
| `cancelDelayTests` | — | `true` | `delay_cancel_failed` |
| `selectProxy` | `{ groupName, proxyName }` | `true` | `bad_args`, `select_proxy_failed` |
| `readSecureProfiles` / `writeSecureProfiles` | encrypted profile JSON bridge | JSON / `true` | `secure_store_*` |
| `readSecureSettings` / `writeSecureSettings` | encrypted TUN/split snapshot | JSON / `true` | `secure_settings_*` |
| `readRuntimeRollback` / `ackRuntimeRollback` | pending/confirmed encrypted crash journal | nullable JSON / `bool` | `runtime_rollback_*` |
| `openVpnSettings` | — | `true` | `vpn_settings_failed` |

`start`'s MethodChannel arguments exist only inside the app process. Before
the service is started they are encrypted into `noBackupFilesDir`; the service
Intent itself contains no arguments. `tunOptionsJson` is a JSON-encoded
VpnService.Builder bundle
(`mtu`, `ipv4Address`/`ipv4Prefix`, `ipv6*`, `dnsServers`, `session`,
`splitMode` ∈ `off|allowed|disallowed`, `apps`). It is a string, not a Map,
so nested lists cross the channel unambiguously. `getInstalledApps` returns
labels only (fast); icons are fetched lazily per-package via `getAppIcon`
(rendered off the main thread, cached in Dart).

`pickConfigFile` launches Android `ACTION_OPEN_DOCUMENT`, then reads the
returned content URI on `Dispatchers.IO` with both provider-size and streaming
16 MiB checks. Only that user-selected URI is visible; no storage permission,
path traversal, persistent URI grant, or third-party picker library is used.

`reloadConfig` is guarded by the same process-wide coroutine mutex as the
VpnService start/stop lifecycle. It preserves the encrypted runtime request id,
writes the replacement config, calls `Binding.reloadConfig`, and restores the
previous encrypted generation if native apply fails. Routing UI mutations are
serialized and roll SharedPreferences back on failure. TUN-equivalent configs
reuse the existing listener/fd; stack, MTU, IPv6, and per-app Builder changes
require a fresh `establish()` and therefore use `restartWithConfig`.
The Go wrapper fingerprints only proxy/provider definitions. Rules-only
reloads reuse the live outbound adapters and selector instead of allocating a
new HY2/QUIC/TLS client set; a real proxy-definition change closes the old
adapters and their provider tasks after successful apply.

`restartWithConfig` atomically stores the replacement encrypted runtime,
requests a native service restart, and waits for `VpnProcessLifecycle`'s
monotonic successful-start generation to advance. The old Kotlin TUN keeper
continues to capture traffic while Go is being replaced, so failure cannot
briefly expose the physical network. Settings and split-tunnel controllers
serialize these transactions. Invalid, unpersistable, or pre-dispatch edits
roll back; once a valid replacement is dispatched, its encrypted desired state
is retained on a native start failure so the fail-closed service can retry it.

### Event channel — `dev.nozelt.nozelt/traffic`

1 frame per second while a foreground Dart subscriber is attached. The Dart
subscriber exists only while the main tab is visible, the app is resumed, and
the VPN is connected. `TrafficStreamHandler` creates its scheduler lazily and
shuts the thread down on cancellation, so disconnected cold starts, background
time, and other tabs have no idle polling worker. Payload is the JSON string
returned by `binding.Binding.getTraffic()`, forwarded
verbatim by `TrafficStreamHandler` after a sanity-parse. After iteration
2 the `synthetic` field is always `false` — real numbers come from
`tunnel/statistic.DefaultManager` on the Go side.

If `Binding.getTraffic()` ever throws or returns malformed JSON, the
frame is dropped (the next tick will retry). This keeps the Dart layer
from crashing on `jsonDecode` of an empty string. A main-thread frame queued
just before background cancellation is delivered only if the same EventSink is
still attached, preventing a late emit into a disposed Flutter stream.

### Event channel — `dev.nozelt.nozelt/logs`

One frame per Go log line:

```json
{ "level": "info|warning|error|debug",
  "message": "...",
  "timestampMs": 1731839280000 }
```

This can carry mihomo's own internal log lines, but the native logger is not
installed until a Dart subscriber attaches. `LoggerImpl` redacts URI and common
credential forms before delivery, writes logcat only from a debuggable build,
and hops every EventSink emit through the main looper. Both queued frames and
Activity detach operations are sink/owner-identity checked, so an old Activity
cannot disconnect or write into a newly recreated diagnostics stream. Normal
release use has no log subscriber and therefore no persistent connection
logging; the Dart log provider is `autoDispose`, so leaving Diagnostics
detaches the native callback again.

For hardware diagnosis only, a debuggable `NozeltVpnService` installs a
redacting logcat fallback when the service is created. A UI EventChannel may
temporarily replace it; owner-aware detach restores the fallback. Release APKs
never install this fallback, so routine connections have no log sink.
All Kotlin lifecycle/error markers use the same release-silent policy; release
builds do not publish network transitions, fd values, or recovery state to
system logcat.

One central Flutter lifecycle provider detaches traffic and periodic status/
latency work when the UI is backgrounded and immediately refreshes native state
on resume. The foreground `VpnService` and Go transport continue independently;
this prevents idle UI timers and streams from accumulating after long screen-off
periods. Timer-driven split-tunnel apply, ping, and Android's default-enabled
GeoIP persistence
also contain their own failures so an unavailable network/Keystore cannot
escape later as an uncaught Flutter zone error.

Startup paints a small branded Flutter bootstrap before awaiting
`SharedPreferences` and the Keystore-backed sensitive-settings snapshot. The
working `ProviderScope` is created only after that snapshot and any confirmed
native runtime rollback are ready, preserving synchronous policy reads without
leaving a slow/unavailable Keystore looking like a frozen native launch screen;
the rare bootstrap failure exposes a retry. A still-pending native replacement
is polled for a bounded interval instead of allowing a late fallback to mutate
storage underneath already-created providers.

### Notification compatibility

The persistent FGS notification uses `androidx.core.app.NotificationCompat`
instead of the framework `Notification.Builder`, and the
`createNotificationChannel` call is guarded by
`Build.VERSION.SDK_INT >= O`. That keeps the service alive across the full
`minSdk = 24` range — Android 7.0/7.1 (API 24-25) predate notification
channels but `NotificationCompat` accepts the channel id as a no-op there.

## 5. NozeltVpnService lifecycle

| Callback          | Triggered by                            | What we do                                          |
|-------------------|-----------------------------------------|-----------------------------------------------------|
| `onCreate`        | first `startForegroundService`          | create the `vpn` notification channel               |
| `onStartCommand`  | `ACTION_START`                          | foreground, build Builder, `establish()`, retain keeper, duplicate fd, `setTunFd`, `start` |
| `onStartCommand`  | Android `VpnService.SERVICE_INTERFACE`  | restore the encrypted runtime as a system-managed Always-on start |
| `onStartCommand`  | `ACTION_STOP`                           | `Binding.stop` (closes Go duplicate), close keeper, stopForeground, stopSelf |
| `onRevoke`        | system revoked the VPN (user/other VPN) | `shutdown()` — same as ACTION_STOP                  |
| `onDestroy`       | service is being torn down              | generation-guarded serialized `Binding.stop`, cancel scope/receivers; never stop a newer service session |

The service returns `START_STICKY` while a VPN is requested and restores its
Keystore-encrypted runtime generation after a framework/OEM recreation. It
returns `START_NOT_STICKY` after an explicit stop. A null Intent never carries
or reconstructs credentials from public state.

The manifest explicitly advertises Always-on support. The VPN service is
discoverable by Android (`exported=true`) but remains guarded by the
signature-level `BIND_VPN_SERVICE` permission, so ordinary third-party apps
cannot start or bind it. On Android 10+ the
service reads both `isAlwaysOn` and `isLockdownEnabled`; on older Android the
diagnostics screen marks lockdown detection as unknown instead of claiming it
is disabled. A stop request originating inside the app is ignored while
Android owns the Always-on lifecycle, and the notification hides its disconnect
action. Revocation by the system still performs a full cleanup.

Foreground type is `specialUse` and the manifest carries
`PROPERTY_SPECIAL_USE_FGS_SUBTYPE = "vpn"`, satisfying the Android 14+
restriction that VPN-style foreground services declare their reason.

## 5a. VpnService.Builder configuration

`NozeltVpnService.establishTun` builds the interface from the tunOptions
bundle:

| Builder call | Value | Notes |
|---|---|---|
| `setSession` | `"Nozelt"` | shown in the system VPN indicator |
| `setMtu` | `settings.mtu` (clamped 1280–9000) | must equal `tun.mtu` in the YAML |
| `addAddress` | `172.19.0.1/30` (+ IPv6 if enabled) | the TUN's own address |
| `addRoute` | `0.0.0.0/0` (+ `::/0` if IPv6) | send all IPs into the TUN |
| `addDnsServer` | `172.19.0.2` | see the DNS-alignment note below |
| `setConfigureIntent` | opens `MainActivity` | tap the VPN indicator → app |
| split tunneling | see §5b | mutually-exclusive allowed/disallowed |

`establish()` may return `null` (permission revoked or another VPN active) —
the service logs and `stopSelf()`s.

**DNS alignment (critical).** The address given to `addDnsServer`
(`172.19.0.2`) is not a real resolver — it only has to route *into* the TUN
(which `addRoute 0.0.0.0/0` guarantees). mihomo's `tun.dns-hijack: [any:53]`
then intercepts every port-53 packet regardless of destination IP and answers
it from the fake-ip pool. The real upstream resolvers are `dns.nameserver`
in the YAML (`TunSettings.nameservers`). If you ever point `addDnsServer` at a
real server *and* disable `dns-hijack`, resolution breaks and the tunnel looks
"connected but no internet". Keep hijack on.

`dns.nameserver-policy` answers `.lan`, `.local`, `localhost`, and reverse
`in-addr.arpa`/`ip6.arpa` lookups with `rcode://success` inside mihomo. This
prevents private host/address structure from reaching public DoH/DoT/DoQ
servers; UDP/5353 mDNS is unaffected. The fake range must be an aligned `/15`
through `/20` subnet inside the RFC 2544 block `198.18.0.0/15`.

## 5b. Split tunneling and the anti-loop rule

`applySplitTunneling` picks exactly one strategy (Android forbids mixing
allowed + disallowed on one Builder):

- **`off`** (default): no application filter; all app UIDs are tunneled.
- **`allowed`**: selected packages plus Nozelt itself are allowed. An empty
  selection falls back to all-apps mode instead of producing a connected VPN
  that protects zero applications. Package installation is revalidated on
  every TUN establishment; if every saved package has been uninstalled, no
  allow-list calls are made and Android's safe all-apps default remains in
  force. If at least one selected package is valid, failure to add Nozelt itself
  aborts establishment rather than weakening the anti-loop invariant.
- **`disallowed`**: only selected packages are excluded; Nozelt is removed from
  the exclusion set so its subscription/GeoIP/UI network traffic remains
  protected. Stale uninstalled packages are ignored and cannot change the
  routing of installed applications.

The anti-loop guard is per socket, not per UID. Before Start, Kotlin installs a
`binding.SocketProtector`; `nozelt-core` assigns its hook to mihomo's
`dialer.DefaultSocketHook`, which covers TCP and UDP/QUIC/HY2 sockets before
connect/bind. `VpnService.protect(fd)` failure aborts the dial. Status exposes
only aggregate `socketProtection`, `protectedSockets`, and
`protectionFailures` counters for the secret-free diagnostics screen.
After protection, Kotlin duplicates the descriptor and applies
`Network.bindSocket(FileDescriptor)` to the selected physical underlay; closing
that temporary duplicate does not own/close Go's fd, while the network mark is
socket-wide. A handover race that invalidates the captured Network returns
success after the already-completed `protect(fd)`, allowing that encrypted
transport socket to follow Android's new physical default. Only failure of the
anti-loop protection itself aborts the dial and increments the failure counter.

Split edits carry a monotonically increasing Dart revision. If a second app
selection arrives while the first fail-closed TUN replacement is in flight,
the notifier waits for the newest encrypted snapshot and schedules a second
apply after the engine becomes connected. A persisted policy can therefore
never be silently newer than the live Android Builder policy.

`auto-route` and `auto-detect-interface` remain forced off: either makes
sing-tun use privileged Android netlink/package paths. The `.aar` is built with
`-tags=cmfa,with_gvisor`.

## 5c. Config assembly and settings persistence

The mihomo YAML is no longer hardcoded — `core/config_builder.dart` assembles
it (and the tunOptions bundle) from two persisted setting objects:

- **`TunSettings`** (`tun_settings.dart`, provider `settings_provider.dart`):
  stack (`gvisor|system|mixed`), MTU, fake-ip range, upstream nameservers,
  and the `dns-hijack` / IPv6 toggles. `auto-route` and
  `auto-detect-interface` are forced off for Android. Validation blocks bad
  MTU/fake-IP/rules, empty DNS, plaintext DNS, and hostname-based encrypted
  resolvers that would require a plaintext bootstrap lookup.
- **`SplitTunnelSettings`** (`split_tunnel_settings.dart`, provider
  `split_tunnel_provider.dart`): the `SplitMode` and the selected package set.

On Android both objects are combined into one versioned snapshot and encrypted
with AES-256-GCM under a dedicated non-exportable Keystore key. `main()` loads
it through the platform channel before the first frame. On the first upgraded
launch, former `tun_settings_v1` / `split_tunnel_v1` SharedPreferences values
are encrypted successfully and only then removed. Domain rules, DNS policy,
and installed-package selections therefore no longer remain readable at rest.
Native secure-store calls are bounded. If the Keystore/read is temporarily
unavailable, that process exposes privacy-first defaults through a deliberately
read-only repository rather than overwriting a possibly valid ciphertext.
Non-Android/test builds retain a serialized SharedPreferences backend until a
native secure store exists there.

One process-wide repository chains complete snapshot writes across both
providers, so a rapid TUN edit and per-app edit cannot overwrite each other.
The MTU used by `setMtu` and the YAML `tun.mtu` come from the same
`TunSettings.mtu`, so they cannot drift. While connected, network-setting and
per-app changes are debounced/serialized into one safe full TUN replacement;
while disconnected they become the next start configuration.

**As of iteration 4 the config is emitted as JSON, not hand-written YAML.**
`config_builder.buildConfig(settings, nodes)` assembles a `Map` and
`jsonEncode`s it. JSON is a valid subset of YAML, so mihomo's `config.Parse`
accepts it (verified by a Go unit test), and it lets us inject mihomo's own
proxy maps (`ProxyNode.raw`) verbatim — with all their nested
`reality-opts` / `xhttp-opts` / `ws-opts` — instead of fragile YAML string
building. The `start(configString)` pipeline is unchanged; only the
serialization format is.

## 5d. Profiles and subscriptions (iteration 4)

A **profile** is a named source of proxy nodes. Three types:

- `manual` — nodes from pasted share links;
- `subscription` — a URL, downloaded and re-parsed on refresh;
- `file` — an imported Clash/mihomo YAML document.

Model: `Profile{ id, name, type, source, nodes[], updatedAt, autoUpdateHours,
userAgent }` where each `ProxyNode` carries mihomo's raw proxy map. Several
profiles coexist; exactly one is active (`ProfilesState.activeId`) and its
nodes feed the config. The model is built to extend to multi-active/merge
without a schema change.

**Persistence.** On Android, `ProfileStore` sends the complete profile JSON to
`SecureProfileStore`, which encrypts it with AES-256-GCM under a non-exportable
Android Keystore key and writes it through `AtomicFile` inside
`noBackupFilesDir`. Android backup/device transfer is disabled in the manifest
and extraction rules. A one-time migration imports and deletes the former
app-private plaintext `profiles.json`; a Keystore/decryption failure fails
closed and never falls back to plaintext or an empty state. Other platforms
keep the atomic private-file backend until their native secure store exists.

**Subscription flow (download = Dart, parse = Go):**

```
UI → ProfilesNotifier.addFromSubscription(name, url, ua, interval)
   → SubscriptionClient.download(url)          [HTTPS-only, safe redirects, size/time limits]
   → engine.parseSubscription(body)            [MethodChannel → Go convert.ConvertsV2Ray]
   → List<ProxyNode>                           [stored in the profile, persisted]
```

The Go side never does network I/O — it only parses already-downloaded
content (base64 link list / plain link list / Clash YAML). Manual links and
imported files reuse the same `parseSubscription` path.

Inputs are capped at 16 MiB, single links at 64 KiB, and one profile import at
4096 proxies. Profile decoding/encoding, every live config build, and parsed
subscription-envelope decoding run on a background Dart isolate. Imported
node/profile names are bounded before UI/config persistence. All-node delay
tests accept HTTPS targets only
and use at most eight worker goroutines/sockets at a time. The UI and state
layer require a connected VPN so proxy hostnames use encrypted DNS and all
probe sockets have Android protection. Native Stop/Reload/Recover cancels and
waits for registered probe contexts before changing resolver/protector state.

**Privacy.** A subscription URL is a secret (often carries a token).
`SubscriptionClient` accepts HTTPS only, refuses redirects to plaintext,
limits redirects and decompressed response size, and never puts a URL/body or
raw client exception in UI/log text. Internal exceptions map to localized,
secret-free messages. URL, user-agent, nodes, and credentials live only in the
encrypted profile record.

**Auto-update.** `autoUpdateHours` per profile; `HomeScreen` calls
`refreshStale()` after the VPN becomes connected, on foreground resume, and
from a foreground maintenance timer. Automatic provider traffic therefore
uses Nozelt's TUN; overlapping triggers share one operation. A manual refresh
or first subscription import is still an explicit disconnected user action.

**Config generation with a profile** (`config_builder`):

- `proxies`: the active profile's `node.raw` maps, injected verbatim.
- `PROXY` is one manual `select` group whose first member is the explicitly
  selected node. There is no automatic-selector group and no hidden `DIRECT`
  member/fallback. Latency checks are explicit HTTPS URL tests managed by
  Nozelt. `Binding.selectProxy` switches
  the live group for new streams; existing TCP/QUIC streams drain naturally.
- `rules` (no geodata dependency): loopback → `DIRECT`; RFC1918, CGNAT,
  link-local, ULA, multicast and limited broadcast → `REJECT` by default or
  `DIRECT` after explicit LAN opt-in; then
  `MATCH,PROXY`. Validated domain/domain-suffix/keyword/CIDR rules are inserted
  first. User-facing global mode is safely implemented as
  mihomo rule mode plus a single `MATCH,PROXY` (mihomo's internal GLOBAL group
  is never used).
- `sniffer` is explicit opt-in. When enabled it parses only HTTP Host, TLS SNI,
  and QUIC Initial metadata on bounded web-port lists, with `parse-pure-ip`, so
  domain rules can cover apps using private DoH or literal IP destinations.
  It runs entirely in-process and is disabled in privacy-first defaults.
- Empty profiles fail closed in both `EngineNotifier.connect` and
  `ConfigBuilder`. Imported node names are normalized to be non-empty, unique,
  and unable to shadow `PROXY`, `DIRECT`, `GLOBAL`, `REJECT`, etc.
  Clash pseudo-outbounds (`direct`, `reject`, `pass`, selectors and similar)
  and malformed remote endpoints are removed at both Go import and Dart/legacy
  decode boundaries; the validated type/server/port must agree with the raw
  mihomo map, and `ConfigBuilder` independently rejects any mismatch. A
  subscription therefore cannot turn a selected "node" into clear underlay
  traffic.
- Profile mutations are serialized across UI selection, ping/GeoIP metadata, and
  background subscription refresh. Active subscription replacement and active
  profile deletion/switching drain the old VPN first, preventing UI/native
  config disagreement. Mutations are rejected during a connect/stop transition;
  active-profile replacement under system-managed Always-on reports an
  explicit system-settings requirement instead of pretending it succeeded.
- The proxy tab uses a lazy sliver list for subscriptions up to the 4096-node
  parser limit. Profiles carry a persisted topology revision, so ping/country
  metadata updates do not rebuild an O(n) name signature; GeoIP results
  are encrypted in batches instead of rewriting the complete profile per node.
  Ping latency is deliberately process-local telemetry: the configured timer
  never serializes and re-encrypts an entire multi-megabyte profile, and an old
  route measurement is not presented as current after process restart.
- fake-IP DNS is always intercepted inside TUN. `nameserver`,
  `default-nameserver`, `proxy-server-nameserver`, and `direct-nameserver` all
  use the same IP-literal encrypted endpoints; the config contains no
  plaintext DNS fallback.
- Local/reverse names are answered empty by mihomo's in-process
  `rcode://success` policy and never reach a public resolver. Fake ranges are
  restricted to aligned `/15`–`/20` subnets of `198.18.0.0/15`.
- `profile.store-selected` and `profile.store-fake-ip` are forced off by both
  the host config builder and `nozelt-core`. No imported config can make mihomo
  open its shared-storage `cache.db`; selected nodes stay in Nozelt's encrypted
  profile and fake-IP mappings remain ephemeral.

## 6. Build

### Prerequisites

- Flutter SDK ≥ 3.41 (Dart ≥ 3.11).
- Android SDK with build-tools matching `compileSdk = 36` (from
  `flutter.compileSdkVersion`).
- Android NDK matching `flutter.ndkVersion`.
- The `nozelt-core` `.aar` built and present at
  `../nozelt-core/build/nozelt.aar`. See its [build instructions](../nozelt-core/ARCHITECTURE.md#7-build).

### Refreshing the .aar

Whenever `nozelt-core` is rebuilt:

```sh
./scripts/sync_aar.sh       # bash / WSL / Git Bash
.\scripts\sync_aar.ps1      # Windows PowerShell
```

The artifact is intentionally not committed to VCS — only the script is.

### Run / build

```sh
flutter pub get
dart run build_runner build       # generate models.g.dart
flutter run -d <android-device>   # dev loop
powershell -ExecutionPolicy Bypass -File ./scripts/build_android_apks.ps1 debug
# Use `release` only with a private production signing config.
```

**Regenerate `models.g.dart` after touching `models.dart`:**
`dart run build_runner build`. Unknown JSON keys are ignored and new fields
default (e.g. `Status.tun` → `TunStatus.down`), so a newer Flutter build
still tolerates an older `.aar`.

**ABI reminder:** the current bridge includes `setTunFd`,
`setSocketProtector`, and `recoverNetwork`. After any `nozelt-core` change you
must `build_aar` **and** `sync_aar`, or Kotlin may call an old ABI and fail at
runtime (`NoSuchMethodError`).

### Pinned values

| Key           | Value | Where               | Reason                                        |
|---------------|-------|---------------------|-----------------------------------------------|
| `minSdk`      | 24    | `app/build.gradle.kts` | `nozelt-core` `.aar` is built with `-androidapi=24` |
| `targetSdk`   | 36    | Flutter `targetSdkVersion` | Current Android behavior/security model   |
| Kotlin        | 2.2.20 | `settings.gradle.kts`  | Flutter scaffold default                     |
| AGP           | 8.11.1 | `settings.gradle.kts`  | Flutter scaffold default                     |
| Java target   | 17    | `app/build.gradle.kts` | AGP 8.x requirement                          |

The application advertises only `arm64-v8a` and `armeabi-v7a`, matching the
gomobile AAR. Publishing x86 Flutter libraries without `libgojni.so` would let
an emulator install an APK that must crash at its first core call. Normal
APK/AAB builds enforce those `ndk.abiFilters`; split builds cannot combine that
Gradle mechanism with ABI splits, so the checked-in helper passes an explicit
ARM target list and Gradle resets the generated split set to the same two ABIs.

## 7. Known limitations and TODO

**Still required before calling Android production-ready:**

- Hardware regression with the test phone: repeated Wi-Fi ↔ cellular handover,
  offline → online recovery, airplane mode, screen-off/Doze, OEM process kill,
  Always-on/lockdown mode, IPv4/IPv6 leak tests, long-run FD/memory sampling,
  and real Helsinki Hysteria2+Gecko traffic. The diagnostics screen provides
  the TUN/protector/listener/FD counters needed for this pass.
- Android exposes the presence of a VPN through system UI and public network
  APIs. No client can honestly hide that from another application. Nozelt
  removes avoidable secondary signals (local proxy ports, blanket UID bypass,
  plaintext DNS, cleartext config/profile files) but does not claim an
  impossible invisible VPN.
- App routing currently supports Android allow/exclude split tunneling.
  Domain/suffix/keyword/CIDR rules support Proxy/Direct/Reject. Combining an
  arbitrary per-app identity with per-domain actions would require reliable UID
  attribution inside the TUN and is not implemented yet.
- Hysteria2 Gecko obfuscation is supported by pinned mihomo v1.19.32;
  `hy2://` links preserve `obfs=gecko` and `obfs-password` through the Go
  parser into the generated config.
- Protocols mihomo's convert does not parse: `wireguard`, `naive`, `ssh`
  (surface as a parse error). Reality `spx` is ignored (server-side only).
- A TUN parameter or per-app Builder change needs a short full reconnect (the
  fd cannot be reused), but the app performs it automatically and keeps the old
  Android TUN keeper in place until the replacement succeeds.
- Active-profile switching and active subscription refresh also use that
  keeper-backed replacement. They never perform a preliminary normal Stop, so
  scheduled maintenance cannot briefly expose the physical underlay when
  Android lockdown is not enabled.
- IPv6 is wired end-to-end but only lightly exercised.
- iOS, macOS, Linux, Windows desktop targets.
- Release signing is intentionally absent; release builds must not use the
  public debug key. A private keystore must be supplied before distribution.
- `QUERY_ALL_PACKAGES` is required by the full per-app picker and needs the
  matching Google Play policy declaration.
- Instrumented Android tests and reproducible CI artifact signing.
- CI to build the APK on every push.

**Known caveats:**

- **TUN fd ownership.** After `establish()`, Kotlin retains the original PFD
  and hands a detached duplicate to Go. Go closes only its duplicate; Kotlin
  atomically replaces/closes only its keeper. The keeper preserves a
  fail-closed Android route while the engine restarts. Full contract in
  [nozelt-core §6a](../nozelt-core/ARCHITECTURE.md#6a-tun-fd-ownership--distinct-descriptors-no-double-close).
  If a replacement engine cannot adopt its new duplicate, Kotlin retains the
  new original as a black-hole interface, keeps encrypted runtime state, and
  makes three fast backoff retries instead of exposing the underlay; a later
  validated physical-network event can safely re-arm the bounded sequence.
- `nozelt-core` is a process-global singleton (mihomo's hub is global).
  Tearing down `NozeltVpnService` does not unload the Go runtime — `Stop()`
  flips the lifecycle flags, closes trackers/outbound adapters/providers and
  DNS/fake-IP memory, runs `executor.Shutdown`, closes non-TUN listeners, and
  clears both global tunnel maps and mihomo's stale TUN comparison state.
  Clearing that state is essential when Android reuses the same numeric fd on
  the next establish; otherwise upstream can report an enabled config without
  recreating the closed listener. Restarting works because we never have more
  than one instance.
- The traffic stream owns no thread while detached. Cancellation shuts its
  daemon scheduler down, and Activity destruction repeats the same idempotent
  cleanup.
- gomobile-generated Java throws `java.lang.Exception` (not a typed
  subclass) when the Go function returns a non-nil `error`. We catch
  `Throwable` in `EngineBridge.*` and propagate the message via the
  MethodChannel error envelope.
- `executor.ApplyConfig` on the Go side never returns errors itself; the
  post-apply port sanity check inside `core.Start` covers the common
  "listener didn't bind" failure mode, but other apply-time issues
  (malformed DNS rule, unsupported sniffer config, etc.) are only visible
  in the log stream. The UI can choose to surface a banner when an
  `error`-level log lands during connect.

## 8. Pointers

- Go engine architecture and ABI: [`../nozelt-core/ARCHITECTURE.md`](../nozelt-core/ARCHITECTURE.md)
- Public Go ABI exported as the `.aar`: [`../nozelt-core/binding/binding.go`](../nozelt-core/binding/binding.go)
- mihomo upstream: <https://github.com/MetaCubeX/mihomo>
