# Аудит UI Nozelt — 13 октября 2026

Это исходный аудит до миграции. Актуальное состояние: [основа](VERIFICATION.md), [импорт](PROFILE_IMPORT.md), [полная тема и DNS, 1.0.0+36](APPEARANCE.md). Утверждения ниже о принудительной dark-теме и отсутствии каталога относятся к исходной версии.

## Основание и границы

Проверены все Dart-файлы `lib/src/ui/`, `lib/main.dart`, существующие widget/golden-тесты, Android-исходники общей Flutter-части и четыре эталона `test/goldens/audit/android_{home,proxies,routing,settings}.png`. Android доступен: отдельной реализации дизайна на Kotlin нет, отличаются оболочка, плотность и некоторые экраны Flutter. Эталоны — тестовые рендеры, а не свежие снимки с телефона; например, флаги Android в старом home-эталоне не отрисованы корректно. Они подтверждают композицию и фирменный стиль, но не доказывают текущее поведение на устройстве.

Go, C++, VPN, применение маршрутов, хранилище профилей и действующее подключение в этой работе не меняются. Release-сборка и установка не входят в этот этап.

## Подтверждённое состояние

- `nozelt_theme.dart` уже задаёт Material 3 и общие темы многих компонентов. Есть полезная основа, её развиваем.
- Есть `NozeltSurface`, `NozeltPageHeader`, `NozeltSectionTitle`, `NozeltEditorBody`, `NozeltPageSaveBar` и специальные connection/latency/flag-компоненты. Вторые версии этих компонентов не нужны.
- Только тёмная тема; `MaterialApp` принудительно использует dark. `NozeltColors` — статическая тёмная палитра, не семантическая тема.
- Исходная инвентаризация: 216 строк обращения к `NozeltColors`, 48 строк с `BorderRadius`, 10 объявлений `SegmentedButton`, 21 `TextField`, 5 `TextFormField`, 13 `SwitchListTile`, 1 `Switch`; 10 локальных `ButtonStyle/styleFrom`. Счётчики включают тему и являются поисковыми совпадениями, а не числом доказанных багов.
- Существующие снимки покрывают много страниц Windows, минимальное окно 720×520 и Android. Общего каталога компонентов и Alchemist нет.

## Повторение и расхождения

Полный исходный индекс объявлений и локальных переопределений находится в [INVENTORY.md](INVENTORY.md). Сходная структура не всегда означает, что нужен общий компонент: сетевые редакторы и карточка подключения имеют разное назначение.

| Семейство | Места | Расхождение и решение |
|---|---|---|
| Выбор режима маршрутизации | `home_tab.dart`, `desktop/desktop_home_tab.dart`, `desktop/desktop_shell.dart` | Одинаковая операция, разные стили сегментов, 44/48 px, дополнительные padding и фиксированная высота. Общий сегментный контрол + явная компактная плотность; перенос в несколько этапов. |
| Другие сегменты | `widgets/core_selector.dart`, `add_profile_screen.dart`, `domain_rule_screen.dart`, `split_tunnel_screen.dart`, `routing_tab.dart`, `settings_tab.dart`, `desktop/connections_tab.dart` | Повторяются оформление и single-select API, локально меняются checkmark, padding и tap target. Общий контрол должен сохранить клавиатуру и semantics Flutter. |
| Поиск | `desktop/connections_tab.dart`, `desktop/logs_tab.dart`, `geo_tags_screen.dart`, `proxy_settings_screen.dart`, `split_tunnel_screen.dart` | Разная плотность полей, иконок и очистки. Особенно toolbar подключений вручную рассчитывает высоту вместе с сегментами. Нужна общая compact-плотность, без фиксированной высоты текста. |
| Редактируемые поля | `add_profile_screen.dart`, `network_settings_screen.dart`, `proxy_settings_screen.dart`, `routing_rule_category_screen.dart`, `routing_profile_config_screen.dart`, `domain_rule_screen.dart` и диалоги маршрутизации/настроек/профилей | Поля с локальным `OutlineInputBorder` обходят радиус темы; helper/error и multiline оформляются отдельно. Общая оболочка `TextFormField`, оформление через `InputDecorationTheme`. Специализированные JSON/code-редакторы остаются отдельными. |
| Булевы настройки | `settings_tab.dart`, `network_settings_screen.dart`, `always_on_vpn_screen.dart`, `routing_profile_settings_screen.dart`, `proxy_settings_screen.dart`, `desktop/desktop_routing_tab.dart` | Отступы 4/12/16, secondary-иконка, подпись и состояния задаются неодинаково; disabled явно не описан темой. Общая switch-tile с родными semantics и фокусом. |
| Действия формы | `widgets/nozelt_ui.dart` (`NozeltPageSaveBar`), `add_profile_screen.dart`, `geo_tags_screen.dart`, редакторы маршрутизации, диалоги | Повторяются spinner/disabled/иконка/подпись. Filled/outlined имеют разные радиусы; TextButton наследует часть стандартных цветов. Общая кнопка с вариантами и состоянием loading; существующая save bar использует её. |
| Поверхности | `NozeltSurface`, `Card`, `_ProfileFrameSegment`, `_NodeTile`, `_VersionsCard`, собственные Container в home/desktop/routing | Радиусы и рамки повторяются; большая часть использует статические dark-цвета. Сначала токенизировать существующий `NozeltSurface`, карточки перенести позже с учётом их роли. |
| Навигация | `NozeltBottomBar`, `DesktopShell/_NavItem`, AppBar/редактор | Платформенные композиции намеренно различаются. Общими должны быть роли цветов, типографика, focus/selected, а не одинаковая геометрия боковой и нижней панели. |
| Статусы и текст | `connection_button.dart`, latency, logs, routing action, diagnostics | Статусы частично raw green/cyan/red, разные TextStyle и веса. Нужны семантические success/warning/info/error и роли TextTheme. Специальная визуализация VPN не переделывается в первой миграции. |

## Дизайн-решения

- Сохранить фирменный бирюзовый акцент, спокойные поверхности и закруглённые карточки Android. Runzoe — только логотип; основной текст Segoe UI на Windows, Roboto на Android.
- Основные роли — `ColorScheme` и `TextTheme`. `ThemeExtension` хранит дополнительные статусы, размеры и состояния. Светлый акцент темнее фирменного cyan ради контраста текста.
- Шкала отступов 4/8/12/16/20/24/32/48; радиусы control 16, card 22, overlay 20. Одно назначение — один токен.
- Windows: компактная работа мышью/клавиатурой; Android: зона касания не меньше 48 dp. Высоты являются минимумами; длинные подписи и масштаб текста увеличивают компонент.
- Обязательны default/hover/focus/pressed/disabled, selected для сегментов, error/read-only для полей, loading для кнопок. Никаких собственных жестов вместо доступных Material-контролов.

## Структура и миграция

```text
lib/src/ui/nozelt_theme.dart             ThemeData и совместимая legacy-палитра
lib/src/ui/design_system/                токены, типографика, общие контролы
lib/src/ui/widgets/nozelt_ui.dart         существующие поверхности/заголовки/save bar
lib/src/ui/design_system/catalogue/      чистые UI-сценарии для каталога и golden
widgetbook/                              отдельное web-приложение разработки
test/design_system/                      поведение, доступность, Alchemist goldens
docs/design-system/                      аудит, контракт, команды и план
```

1. Основа: dark/light × Windows/Android, токены, темы Material, совместимость существующих импортов.
2. Первая вертикаль: NozeltButton, NozeltTextField, NozeltSwitchTile, NozeltSegmentedControl. Применить в добавлении профиля, выборе ядра, save bar и контролах настроек. Обработчики и сохранение не менять.
3. Widgetbook: отдельная dev-зависимость, чтобы его плагины не меняли native runner production-приложения. Каталог тем, плотностей, состояний, длинного текста и композиции формы.
4. Alchemist: человекочитаемые Windows-эталоны и переносимые CI-эталоны; компоненты, настоящие экраны добавления профиля/настроек, компактные окна и масштабирование.
5. Следующие этапы: поиск/toolbar и остальные сегменты; затем карточки/статусы; затем навигация и полная миграция статических цветов. Только после этого включать переключение светлой темы всего приложения.

Светлая тема в этом этапе гарантируется для основы, общих компонентов и перенесённых форм. Неперенесённые страницы сохраняют dark-only значения; наличие `NozeltTheme.light` не означает готовность всего старого UI к светлому режиму.

## Проверка

Анализ основного приложения и Widgetbook, полный существующий набор тестов, отдельные тесты клавиатуры/semantics/валидаторов, Alchemist без увеличения допуска различий. Обновлённые эталоны обязательно просматриваются рядом с исходными. Проверка Android-раскладки в Flutter-тестах не заменяет проверку на устройстве.

Источники API: [ThemeExtension](https://api.flutter.dev/flutter/material/ThemeExtension-class.html), [Widgetbook](https://docs.widgetbook.io/addons/overview), [Alchemist](https://pub.dev/packages/alchemist).
