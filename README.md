# Nozelt

VPN-клиент для Android и Windows. Подписки Clash/Mihomo, Xray (в том числе Happ) и sing-box, три ядра на выбор, маршрутизация по правилам и защита от утечек.

## Скачать

Готовые сборки лежат в [Releases](https://github.com/XXo-01/Nozelt/releases/latest).

| Платформа | Файл |
| --- | --- |
| Android, современные телефоны | `Nozelt-…-android-arm64-v8a.apk` |
| Android, старые 32-битные телефоны | `Nozelt-…-android-armeabi-v7a.apk` |
| Windows 10/11, установщик | `Nozelt-…-windows-x64-setup.exe` |
| Windows 10/11, портативная версия | `Nozelt-…-windows-x64-portable.zip` |

## Возможности

- Ядра **Mihomo**, **Xray** и **sing-box**: ядро выбирается автоматически по формату подписки или вручную.
- **Маршрутизация**: GeoIP, GeoSite, домены, IP-сети, процессы Windows, приложения Android. Правила пользователя всегда выше правил из подписки.
- **Автосервер Nozelt**: сам проверяет все серверы подписки и держит подключение на самом быстром. Работает на любом ядре.
- **Защита**: на Windows блокировка трафика мимо VPN снимается при любом отключении, сбое или закрытии программы, интернет без Nozelt работает всегда. DNS идёт через туннель, ping не уходит мимо VPN.
- Расширенные настройки DNS и TUN на обеих платформах.

## Структура

- `nozelt-app` — приложение на Flutter (Android и Windows).
- `nozelt-core` — ядро на Go поверх Mihomo: библиотека для Android (gomobile) и DLL для Windows.
- `native-cores` — сборка Xray и sing-box для Android и Windows.

## Сборка

Нужны Flutter, Go, Android SDK и NDK.

```powershell
# Ядро
nozelt-core\scripts\build_aar.ps1            # Android
nozelt-core\scripts\build_windows_dll.ps1    # Windows
nozelt-app\scripts\sync_aar.ps1

# Приложение
nozelt-app\scripts\build_android_apks.ps1 release
nozelt-app\scripts\build_windows_portable.ps1 -SkipCore
```

Установщик Windows собирается из `nozelt-app\installer\nozelt.iss` (Inno Setup 6).

## Лицензия

GPL-3.0, см. [LICENSE](LICENSE). Nozelt использует Mihomo (GPL-3.0), sing-box (GPL-3.0-or-later), Xray-core (MPL-2.0) и Wintun; их лицензии лежат в `native-cores/licenses`.
