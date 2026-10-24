# Дизайн-система Nozelt

Общая основа Flutter для Windows и Android. [Аудит и миграция](AUDIT.md), [исходный индекс](INVENTORY.md), [результаты первого этапа](VERIFICATION.md).

Последующие итерации: [быстрый импорт профилей и Android QR](PROFILE_IMPORT.md), [оформление, плотность и DNS в 1.0.0+36](APPEARANCE.md), [скругление подсветки в 1.0.0+37](HOVER.md).

Настольная переработка от 18 октября: [композиция, DNS/TUN и проверка](DESKTOP_REFINEMENT.md). Редизайн Windows от 20 октября: [общая колонка, главная, подстраницы](WINDOWS_REDESIGN.md).

## Структура

| Файл | Назначение |
|---|---|
| `lib/nozelt_design_system.dart` | Публичный UI-only API |
| `lib/src/ui/nozelt_theme.dart` | Совместимый импорт для старых страниц |
| `lib/src/ui/design_system/nozelt_material_theme.dart` | ThemeData и темы Material-компонентов |
| `nozelt_tokens.dart` в той же папке | ThemeExtension, статусы, размеры, отступы, радиусы, состояния |
| `nozelt_typography.dart` | Роли TextTheme и платформенные шрифты |
| `nozelt_controls.dart` | Общие кнопки, поля, switch-tile и single-select сегменты |
| `lib/src/ui/widgets/nozelt_ui.dart` | Существующие поверхности, заголовки, editor body и save bar |
| `lib/src/ui/design_system/catalogue/showcase.dart` | Чистые UI-сценарии каталога и golden |
| `widgetbook/` | Отдельное web-приложение разработки |
| `test/design_system/` | Поведение, доступность, Alchemist; конфигурация ограничена этой папкой |

## Цвета

Основные роли — `Theme.of(context).colorScheme`: primary/onPrimary для главного действия; primaryContainer для выбора; surface/onSurface для карточки и текста; onSurfaceVariant для вторичного текста; outline для контролов; outlineVariant для декоративной рамки; error/onError для опасного действия/ошибки.

`context.nozelt.success`, `warning`, `info` — дополнительные статусы. Акцент в dark — фирменный cyan `#08C7F4`, в light — `#006E8C`, чтобы акцентный текст оставался контрастным на белом. Фон приложения берётся из scaffoldBackgroundColor. Контраст основных текстовых ролей, статусов и onPrimary/primary проверяется тестами: минимум 4.5:1. Disabled намеренно приглушён и не используется для обычных пояснений.

`NozeltColors` оставлена только для совместимости импортов; обращения из страниц перенесены на роли темы. Не используй её в UI. С версии 1.0.0+36 светлая тема включена в приложении: Настройки → Тема оформления → Тёмная / Светлая / Системная. Выбор сохраняется; для старых настроек по умолчанию остаётся тёмная тема.

## Типографика и размеры

- Windows: Segoe UI; Android: Roboto. Roboto также является резервным шрифтом, в web-каталоге загружается локально. Runzoe только в логотипе.
- Windows: headlineMedium 26, titleLarge 20, titleMedium 15, bodyLarge 14. Android: headlineMedium 28; titleLarge 22; titleMedium 16; titleSmall 14; bodyLarge 16; bodyMedium 14; bodySmall 12; labelLarge 14; labelMedium 12; labelSmall 11. Используется роль TextTheme, не её локальная копия.
- `NozeltSpacing`: 4/8/12/16/20/24/32/48. Радиусы из context.nozelt: Windows control 12, card 18, overlay 14; Android 16/22/20. Tooltip 8.
- Минимумы Windows: кнопка 40, поле/сегменты 44, compact 36. Android: кнопка/поле/сегменты/compact 48. Высоты в логических пикселях являются минимумами; текст не зажимается при масштабировании. Геометрия задаётся явно при стандартной VisualDensity, чтобы Flutter не уменьшал нарисованную рамку полей на Windows на дополнительные 8 px.
- Ширина редактора до 960, диалога до 560. Compact 600 и wide 1024 предназначены для новых композиций; старые специализированные breakpoint мигрируются отдельно.
- Hover 8%, focus 12%, pressed 16%; disabled text 38%, disabled fill 12%; переход 180 ms. У действий видимый focus border; у поля focused/error border 2 px.

## Компоненты

```dart
import 'package:nozelt/nozelt_design_system.dart';

NozeltButton(label: 'Добавить профиль', icon: const Icon(Icons.add_rounded), onPressed: addProfile);
NozeltTextField(controller: nameController, label: 'Название', validator: validateName);
NozeltSwitchTile(title: const Text('Автоподключение'), value: enabled, onChanged: setEnabled);
```

`NozeltButton`: primary, secondary, tertiary, destructive; icon, loading, native focus и statesController. Loading блокирует повторное действие. Когда подпись состояния отличается от обычного действия, передавай локализованную строку состояния.

`NozeltPopupMenuButton<T>` сохраняет родной PopupMenuButton и его callbacks/клавиатуру, но включает Clip.antiAlias для меню и общий радиус для child-trigger. В Flutter 3.41 PopupMenuTheme задаёт shape, но не имеет clipBehavior: одной скруглённой рамки недостаточно. Все меню приложения используют этот адаптер. У DropdownButton/FormField указывай borderRadius из токенов — он также включает обрезку содержимого dropdown-route.

`NozeltSurface` всегда создаёт собственный Material с формой карточки и Clip.antiAlias, включая карточки без общего onTap. Поэтому ListTile/SwitchListTile и вложенные кнопки рисуют ink на своей поверхности. Не заменяй его DecoratedBox с одной скруглённой рамкой: она не обрезает подсветку. NozeltButton, Card, Dialog и BottomSheet тоже обрезают содержимое по форме; отдельные нативные InkWell используют соответствующий borderRadius.

`NozeltTextField`: TextFormField с controller/initialValue, validator, error/helper, read-only/disabled, multiline, клавиатурой и форматтерами. Border и цвета задаёт InputDecorationTheme. Специализированный code/JSON-редактор может использовать TextField напрямую с общей темой.

`NozeltDropdownField<T>`: родной DropdownButtonFormField с той же высотой рамки, что у поля/сегментов. Учитывает резервируемую Flutter строку 24 dp; отступы вычисляются по токену. AutoUpdateIntervalField и DNS/TUN используют его. При проверке сравнивай InputDecorator.containerOf — размер внешнего FormField включает область ошибки и сам по себе не доказывает совпадение рамок.

`NozeltSettingsGroup`: заголовок и связанные строки внутри существующей NozeltSurface; разделители и отступы общие. Не добавляй отдельную карточку вокруг каждого поля.

`NozeltSettingsField`: постоянная подпись рядом с контролом при ширине ≥520 на Windows / ≥640 на Android и обычном масштабе; сверху при узком окне или крупном тексте. Необязательный help открывается по значку информации и доступен через tooltip. Значения, валидация и сохранение остаются ответственностью формы.

Длинная floating-подпись поля при большом масштабе может использовать стандартное многоточие Material. Полный текст сохраняется в semantics и доступен в подсказке при наведении; сама вводимая строка прокручивается нативным редактором. Ошибки/пояснения и подписи переключателей переносятся.

`NozeltSwitchTile`: нативный SwitchListTile с общей геометрией. Отдельные интерактивные ссылки в title/subtitle конфликтуют с MergeSemantics.

`NozeltSegmentedControl<T>`: одиночный выбор. Сначала скрывает декоративные иконки, если подписи помещаются; затем использует вертикальную композицию. Измеряет ширину слов с реальным TextScaler, не уменьшает текст. В обеих раскладках задаются конечные размеры, рассчитанные по подписи и TextScaler; expandedInsets не меняется при повороте. Это предотвращает бесконечную высоту в скролле, неполную заливку и обрезку подписей.

`NozeltSurface`, заголовки, `NozeltEditorBody`, `NozeltPageSaveBar` развиты на месте. Вторая save bar или поверхность для того же назначения не нужна.

`NozeltDialogBody` задаёт конечную intrinsic-ширину содержимого AlertDialog и прокрутку формы. Используй его для диалогов с responsive-контролами: LayoutBuilder нельзя непосредственно помещать под IntrinsicWidth AlertDialog. Действия диалога остаются вне скролла. Первый перенесённый случай — редактирование VPN-профиля с CoreSelector.

## Первая миграция

- Добавление профиля: выбор способа, поля, действия импорта/добавления.
- CoreSelector и AutoUpdateIntervalField: оформление из темы, общее поле пользовательского интервала.
- Существующая save bar: общие кнопки, состояние загрузки, платформа из ThemeData.
- Switch-tile основных настроек: прежние callbacks, общие отступы и состояния.
- Формы DNS/TUN: общие поля, переключатели и семантические цвета. Сохранение и сетевые операции не менялись.
- Общие поверхности и заголовки: семантические цвета вместо статической dark-палитры.
- Фильтр уровня логов: TextTheme вместо TextStyle без семейства шрифта; логика фильтра не меняется.

В 1.0.0+36 выполнена миграция статических цветов всех страниц, навигации, статусов, логов и диалогов. Композиция основных страниц сохранена. DNS/TUN сгруппированы в карточки; дополнительные резолверы и кэш раскрываются, основные подписи не исчезают при вводе. Переключатель маршрутизации в боковой панели использует общий сегментный компонент. Дальнейшие переносы поиска и специальных карточек должны развивать существующие компоненты, сохраняя сетевое поведение.

## Widgetbook

```powershell
cd nozelt-app/widgetbook
flutter pub get
flutter run -d chrome
```

Или `flutter build web --release --no-pub --no-web-resources-cdn`, затем локально обслуживать `build/web`. Каталог: Tokens, Buttons, Fields, Switches, Segments, Editor, Profile import, Settings, Interactions. Есть dark/light × Windows/Android; viewport 720×520, 1180×760, 360×800, 412×915; RU/EN; масштаб 100–200%.

Тема и viewport независимы: для Android выбери Android в обоих. Каталог не инициализирует VPN и не читает реальные профили. Editor — композиционный сценарий; настоящие AddProfile/DNS/TUN/Settings проверяются golden-тестами с mock engine.

Roboto и его лицензия включены локально в каталог; CanvasKit можно обслуживать без CDN указанной командой. В web доступность системного Segoe UI зависит от renderer/браузера; точный Windows-эталон типографики — читаемые Alchemist-снимки с настоящими локальными шрифтами Windows. Шрифт Microsoft не копируется в публичные web-ресурсы.

Widgetbook 3.23 совместим с Flutter 3.41.9. Версии 3.24/3.25 требуют Flutter >=3.44, поэтому SDK проекта не меняется. Зависимости Widgetbook изолированы; основной пакет получает только dev-зависимость Alchemist 0.14.1.

## Проверка

Из `nozelt-app`:

```powershell
flutter analyze --no-pub
flutter test --no-pub test/design_system
flutter test --no-pub
```

Каталог отдельно из `widgetbook`: `flutter analyze --no-pub`, `flutter build web --release --no-pub`.

Создание новых эталонов — адресно: `flutter test --no-pub --update-goldens test/design_system`. Просмотреть результат и diff, затем прогнать без обновления. Допуск разницы нулевой.

`test/design_system/goldens/windows` — читаемый текст на Windows; Android-варианты там являются Android-раскладкой, отрендеренной на Windows. `goldens/ci` — скрытый текст Alchemist, не замена проверки локализации. `golden_config.dart` дополнительно переводит явные шрифты компонентных тем в Ahem: Alchemist самостоятельно меняет только TextTheme. Не убирай семейство шрифта из production-темы ради CI — Tooltip/ListTile не всегда объединяют частичный стиль с TextTheme. Анимации загрузки снимаются после фиксированного времени.

Поведенческие тесты проверяют Enter/Space, блокировку loading/disabled, Form validation, read-only, semantics, смену размеров, сохранение выбора, границы подписей и длинный русский текст при 200%. Старые UI-audit и DNS/TUN goldens сохраняются.

`interactions_golden_test.dart` проверяет настоящее наведение мыши и удержание кнопки: основные/вторичные/текстовые кнопки, иконка, карточка, первая/последняя строка, trigger и первый/последний пункт popup/dropdown, сегменты. После moveTo сначала pump для создания hover-animation, затем pump её длительности: один pump(Duration) может снять ещё прозрачную подсветку. UI-audit отдельно открывает меню темы в настоящем NozeltApp при 720×520/1180×760 и проверяет закрытие Escape.
