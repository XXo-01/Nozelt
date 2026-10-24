# Nozelt Android hardware regression checklist

Run this after installing the current debug APK on the test phone. The goal is
to validate the Android/VpnService boundary that unit tests cannot emulate.
Never paste a subscription URL, password, or complete config into the log.

## 1. Prepare

```powershell
$adb = '%USERPROFILE%\AppData\Local\Android\sdk\platform-tools\adb.exe'
$apk = '%USERPROFILE%\Desktop\Nozelt\nozelt-app\build\app\outputs\flutter-apk\app-arm64-v8a-debug.apk'
$log = '%USERPROFILE%\Desktop\Nozelt\nozelt-android-regression.log'
& $adb install -r $apk
& $adb logcat -c
& $adb logcat -v time 'NozeltVpnService:V' 'nozelt-core:V' 'MainActivity:V' '*:S' |
  Tee-Object -FilePath $log
```

In a second PowerShell window:

```powershell
$adb = '%USERPROFILE%\AppData\Local\Android\sdk\platform-tools\adb.exe'
```

On Android 13+, clear/reinstall once and connect. Nozelt should ask for
notification permission only after this explicit action. Accept it and verify
the ongoing VPN notification uses the monochrome logo; switch RU/EN and verify
its text changes immediately. Reinstall once more and decline: the VPN must
still connect, and reconnecting must not repeatedly show the same prompt.

## 2. Helsinki HY2 + Gecko baseline

1. Select the Helsinki Hysteria2/Gecko node and connect on mobile data.
2. Open several HTTPS sites and a video stream.
3. Confirm the public IP is the Helsinki VPS IP, not the mobile operator IP.
4. Open **Settings → Diagnostics**. Expected while connected:
   - VPN core: Running;
   - TUN: Active, stack `gvisor` unless deliberately changed;
   - Transport socket protection: Enabled;
   - Protected sockets increases after opening sites;
   - Protection failures: `0`;
   - Local proxy ports: Closed;
   - open file descriptors normally below 512.
5. Leave traffic running for five minutes. There must be no reconnect loop,
   rapidly increasing FD count, or local HTTP/SOCKS listener.
6. Logs must not contain a `cache.db` or `/sdcard/.config/mihomo` warning.
7. After opening the upgraded app once, this filename-only check should list
   `profiles.enc`, `vpn-runtime.enc` while requested, and
   `sensitive-settings.enc`; it must not print either legacy settings key:

```powershell
& $adb shell run-as dev.nozelt.nozelt ls no_backup
& $adb shell run-as dev.nozelt.nozelt grep -R -l -e tun_settings_v1 -e split_tunnel_v1 shared_prefs
```

## 3. Wi-Fi ↔ mobile handover

Repeat this cycle at least five times while a site/video is active:

1. mobile → enable Wi-Fi and wait until Android marks it connected;
2. Wi-Fi → disable Wi-Fi and return to mobile;
3. after each switch, open a new HTTPS page and refresh diagnostics.

Expected: a short pause is acceptable; traffic must recover without toggling
Nozelt. Logs should show `underlying network=... changed=true` followed by
`network handover recovery complete`. If three in-place attempts fail, one
`full VPN restart` is acceptable, followed by a working tunnel.

Generate noisy callbacks during one transition (toggle Wi-Fi once while it is
still validating, or roam between access points). The recovery retry loop must
finish despite later capability/link updates; Nozelt must not remain stuck
after only `attempt=1` with Android still showing the VPN icon.

Also leave Wi-Fi associated but remove its Internet access (for example,
disconnect the router WAN) while mobile data remains available. Nozelt must
prefer the validated cellular underlay instead of staying pinned to the
unvalidated Wi-Fi network.

While remaining on one Wi-Fi network, renew DHCP or roam between access
points with the same SSID. A changed address/DNS/interface must trigger the
same recovery even if Android keeps the original `Network` object.

If the device/OEM exposes a per-app network block (Data Saver, managed profile,
or vendor firewall), block Nozelt's physical network while connected. New
traffic must stop inside the retained TUN, not escape through another route;
unblocking it or making a second validated underlay available must recover
automatically.

Before this sequence choose a non-first proxy node. After every handover verify
that the same node is still selected and that its public exit IP did not revert
to the profile's first node.

Keep one browser page repeatedly requesting several hostnames during the cycle.
If recovery escalates to `full VPN restart`, cached `198.18.0.0/15` FakeDNS
addresses must continue working after the replacement; there must be no state
where Android shows VPN connected but every cached site stays broken until an
app/DNS-cache restart. Diagnostics must not report socket-protection failures.

## 4. Offline → online and fail-closed behavior

1. While connected, enable airplane mode. Existing traffic must stop; it must
   not fall back to the physical network.
2. Disable airplane mode and enable either mobile data or Wi-Fi.
3. Confirm Nozelt recovers automatically and the public IP is still the VPN.
4. Also start Nozelt while the phone is offline, then restore connectivity.
   The null-underlay → physical transition must re-arm an exhausted start and
   recover after Android reports the network as validated.

## 5. Rapid lifecycle race

Perform 20 connect/disconnect cycles, including several immediate reconnects.
The button should remain in **Disconnecting** until the Go core is actually
down. Expected after every reconnect: one active TUN, no missing encrypted
runtime config, no `already running`, and no FD trend across cycles.

Useful snapshots:

```powershell
& $adb shell pidof dev.nozelt.nozelt
& $adb shell dumpsys meminfo dev.nozelt.nozelt
& $adb shell dumpsys connectivity
```

## 6. Background, idle, and Doze

1. Connect, send Nozelt to the background, lock the screen for 30–60 minutes,
   then unlock and reopen it. The UI must not crash and must restore the native
   connected state without loading a second engine.
2. Compare Diagnostics FD/Go-task counts before and after the idle period.
3. Optional controlled Doze test:

```powershell
& $adb shell dumpsys deviceidle force-idle
# wait a few minutes, wake/unlock, then:
& $adb shell dumpsys deviceidle unforce
```

The foreground VPN should remain alive or restore from the Keystore-backed
runtime record. Always run `unforce` after the test.

On a cold launch and after the long-idle return, the branded Flutter loading
screen should appear promptly even if Keystore restoration is still running;
there must be no several-second frozen native splash. Once restoration fails,
the loading screen must offer a retry instead of terminating the process.

If the core cannot restore within the bounded window, the UI must show an error
or reconnecting state rather than retaining a stale **Connected** label. On
foreground return it should dispatch one bounded rebuild and recover if the
encrypted config is valid; with Always-on/lockdown, ordinary traffic must
remain blocked throughout.

Also choose a non-first node, kill the app process while the VPN is requested,
and let Android restore the service. Without opening Flutter first, verify the
exit IP still belongs to the chosen node; then open Nozelt and confirm the UI
matches it.

Open Android's Recents/Overview screen while a profile and node are visible.
The Nozelt card must show the last rendered page instead of a black rectangle,
and returning through that card must restore the same tab. A normal foreground
screenshot should also keep working.

## 7. Always-on VPN and lockdown

Open **Settings → Always-on VPN and leak blocking**, select Nozelt, enable
Always-on VPN and **Block connections without VPN**. Verify:

1. force-stop/reboot/recreation starts Nozelt through Android's system action
   and restores the encrypted runtime after device unlock; if the first start
   happened while Keystore was locked, logcat should show
   `user storage unlocked; retrying requested VPN start` and recover without
   opening/toggling Nozelt;
2. the in-app button and notification cannot disconnect a system-managed
   Always-on tunnel and explain that it must be disabled in Android settings;
   switching/deleting/refreshing the active profile must show the same clear
   requirement and must not display a false success message;
3. Diagnostics reports Always-on and the system kill switch as enabled (or
   explicitly says the lockdown value must be checked manually on API 24–28);
4. while Nozelt/VPS is unavailable, ordinary apps have no network instead of
   bypassing the VPN;
5. disabling lockdown restores normal Android behavior.

## 8. DNS, IPv6, and local-surface checks

1. Run a DNS leak page: resolvers must correspond to configured encrypted DNS,
   not the ISP. The config contains no plaintext DNS fallback.
   Queries for a made-up `.local`/`.lan` name and reverse lookup should return
   empty/fail quickly and must not appear at the public resolver. Editing the
   fake-IP CIDR outside `198.18.0.0/15` or with a prefix longer than `/20`
   must be rejected.
2. With IPv6 disabled, an IPv6-only check must fail rather than leak outside
   the tunnel. With IPv6 enabled, repeat and confirm the address is tunneled.
3. Diagnostics must continue to show all local proxy ports closed.
4. Test a domain Proxy rule, Direct rule, and Reject rule, then verify their
   order (top to bottom). While connected, toggle/save/delete each rule and
   verify the behavior changes without the Android VPN icon disappearing.
   Then enable **Detect domains from traffic** and repeat with an application
   that uses private DoH: HTTPS/HTTP/3 domain rules should begin matching,
   ordinary HTTPS browsing must remain stable, and disabling it must hot-reload
   without dropping the Android VPN interface.
5. Switch between two working nodes while connected. New HTTPS connections
   must use the new node immediately; an existing stream may drain normally.
   Then switch between two profiles and manually refresh the active
   subscription. The Android VPN icon must remain present throughout both
   keeper-backed replacements, and continuous leak-test traffic must either use
   the old/new tunnel or pause—never reach the physical underlay.
   Repeat once with an intentionally unreachable node/profile: the operation
   must report failure, restore the previously selected profile/node definitions
   in the UI, and recover the previous tunnel without another user toggle.
   Verify ping buttons are disabled while disconnected, then connect and test
   one/all nodes; disconnect during an all-node test and confirm Stop completes
   without any later direct DNS/socket activity.
6. Test All / Only / Except app routing separately. Each saved change must
   automatically perform one short TUN replacement; the Android VPN icon must
   remain present and traffic must stay blocked until the replacement works.
   During one replacement, quickly toggle another two applications. After the
   engine returns, the live routing must match the final checkbox revision—not
   the first intermediate selection. Then select a disposable application as
   the sole entry in Only mode, disconnect, uninstall that application, and
   reconnect. All remaining applications must still be tunneled; a stale
   allow-list must never turn into clear-network bypass. A stale package in
   Except mode must likewise have no effect on installed applications.
   Force one Builder/replacement failure: the last working per-app mode and
   checkbox set must return in both UI and encrypted state, and its old tunnel
   must recover automatically. Also overlap a per-app edit with an MTU/profile
   edit; replacements must run sequentially and the final tunnel must contain
   the complete union of both choices.
7. While connected, change MTU, stack, IPv6, and DNS one at a time. Each valid
   edit must apply after one serialized restart; a rejected value must leave
   both the old preference and the active tunnel untouched.
8. During one replacement, temporarily use an invalid/unreachable test node.
   New traffic must stop, the VPN icon must remain present through the bounded
   retries, and the public underlay IP must never become reachable. For an
   MTU/IPv6/DNS-setting replacement, the UI action must report failure, restore
   the previous encrypted value, and automatically bring the previous live
   configuration back without dropping the VPN icon.
   Repeat the unreachable replacement and immediately swipe Nozelt from
   Recents (or enable **Don't keep activities**) before the UI can handle the
   failure. Leave the foreground VPN service requested. After bounded native
   retries plus the fallback delay, the previous working exit must return
   without reopening Flutter; the physical IP must remain unreachable for the
   whole interval. Reopening Nozelt must restore a connected native-core state
   without crashing; durable UI reconciliation remains a separate follow-up
   scenario and is not an acceptance claim of this native fallback test.
   Also force the same failure on the very first connection after a clean
   disconnect. As soon as the Android VPN icon appears, leak-test traffic must
   stop rather than fall back to the physical IP; the notification must say
   that the secure tunnel is being restored and traffic is blocked. Tapping
   Disconnect must then deliberately release the block.
9. With automatic country detection enabled, disconnect Nozelt and reopen the
   proxy list: there must be no Cloudflare/ipwho.is request until VPN becomes
   connected. Likewise, a due automatic subscription refresh must wait for an
   active VPN; a manual first-profile import remains an explicit exception.
10. Import a large synthetic subscription (at least 1000 nodes), open the proxy
    tab, scroll rapidly, run one selected-node ping, and background/resume.
    Visible rows should remain smooth and memory must not jump in proportion to
    every off-screen card; GeoIP persistence should occur in batches.

## 9. Acceptance criteria

- Helsinki HY2+Gecko transfers real traffic on Wi-Fi and mobile.
- Five bidirectional handovers and offline→online recover without user action.
- Twenty rapid lifecycle cycles produce no missing-config/already-running race.
- No plaintext DNS, IPv6 fallback, open local proxy/controller port, or
  protection failure.
- FD count stays bounded (normally below 512; the emergency guard triggers at
  1024) and memory does not trend upward during a one-hour idle/traffic run.
- The app resumes without a crash after screen-off/Doze and reports the same
  native VPN state.

If any item fails, keep the full log file plus a copied **safe diagnostics**
report. The report intentionally excludes subscription URLs, endpoints, keys,
profile names, and connection logs.
