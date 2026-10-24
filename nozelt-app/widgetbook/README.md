# Nozelt Widgetbook

Локальный каталог общей дизайн-системы Windows/Android. Команды, состояния и правила: [DESIGN_SYSTEM.md](../docs/design-system/DESIGN_SYSTEM.md).

```powershell
flutter pub get
flutter run -d chrome
```

Сборка без CDN: `flutter build web --release --no-pub --no-web-resources-cdn`. Каталог использует публичный UI-only API Nozelt и не запускает VPN или хранилище профилей.
