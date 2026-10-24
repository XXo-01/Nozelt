import 'package:flutter/material.dart';
import 'package:nozelt/src/ui/design_system/nozelt_design_system.dart';

bool _ru(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'ru';

/// Real controls for pointer-state checks, including the first/last menu rows.
class NozeltInteractionShowcase extends StatefulWidget {
  const NozeltInteractionShowcase({super.key});
  @override
  State<NozeltInteractionShowcase> createState() =>
      _NozeltInteractionShowcaseState();
}

class _NozeltInteractionShowcaseState extends State<NozeltInteractionShowcase> {
  String _choice = 'dark';
  int _segment = 0;
  @override
  Widget build(BuildContext context) {
    final ru = _ru(context);
    final options = <(String, String)>[
      ('dark', ru ? 'Тёмная' : 'Dark'),
      ('light', ru ? 'Светлая' : 'Light'),
      ('system', ru ? 'Системная' : 'System'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: NozeltSpacing.md,
          runSpacing: NozeltSpacing.md,
          children: [
            for (final variant in [
              NozeltButtonVariant.primary,
              NozeltButtonVariant.secondary,
              NozeltButtonVariant.tertiary,
            ])
              NozeltButton(
                key: ValueKey('interaction-${variant.name}'),
                variant: variant,
                label: ru ? 'Действие' : 'Action',
                onPressed: () {},
              ),
            IconButton(
              key: const ValueKey('interaction-icon'),
              onPressed: () {},
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        const SizedBox(height: NozeltSpacing.lg),
        NozeltSurface(
          key: const ValueKey('interaction-surface'),
          onTap: () {},
          child: Text(ru ? 'Кликабельная карточка' : 'Interactive card'),
        ),
        const SizedBox(height: NozeltSpacing.lg),
        NozeltSurface(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              ListTile(
                key: const ValueKey('interaction-first-row'),
                title: Text(ru ? 'Первый пункт' : 'First row'),
                onTap: () {},
              ),
              ListTile(
                key: const ValueKey('interaction-last-row'),
                title: Text(ru ? 'Последний пункт' : 'Last row'),
                onTap: () {},
              ),
            ],
          ),
        ),
        const SizedBox(height: NozeltSpacing.lg),
        NozeltSurface(
          child: Row(
            children: [
              Expanded(child: Text(ru ? 'Тема оформления' : 'Appearance')),
              NozeltPopupMenuButton<String>(
                key: const ValueKey('interaction-popup'),
                tooltip: '',
                initialValue: _choice,
                onSelected: (value) => setState(() => _choice = value),
                itemBuilder: (_) => [
                  for (final option in options)
                    PopupMenuItem(value: option.$1, child: Text(option.$2)),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: NozeltSpacing.md,
                    vertical: NozeltSpacing.sm,
                  ),
                  child: Text(
                    options.firstWhere((option) => option.$1 == _choice).$2,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: NozeltSpacing.lg),
        NozeltDropdownField<String>(
          key: const ValueKey('interaction-dropdown'),
          value: _choice,
          label: ru ? 'Выбор' : 'Selection',
          onChanged: (value) => setState(() => _choice = value!),
          items: [
            for (final option in options)
              DropdownMenuItem(value: option.$1, child: Text(option.$2)),
          ],
        ),
        const SizedBox(height: NozeltSpacing.lg),
        NozeltSegmentedControl<int>(
          key: const ValueKey('interaction-segments'),
          value: _segment,
          onChanged: (value) => setState(() => _segment = value),
          segments: [
            ButtonSegment(value: 0, label: Text(ru ? 'По правилам' : 'Rules')),
            ButtonSegment(value: 1, label: Text(ru ? 'Глобально' : 'Global')),
          ],
        ),
      ],
    );
  }
}

class NozeltSettingsFieldShowcase extends StatelessWidget {
  const NozeltSettingsFieldShowcase({super.key});
  @override
  Widget build(BuildContext context) {
    final ru = _ru(context);
    return NozeltSettingsGroup(
      title: 'DNS',
      icon: Icons.dns_outlined,
      children: [
        NozeltSettingsField(
          label: ru ? 'Основные серверы DNS' : 'Primary DNS servers',
          help: ru
              ? 'По одному адресу сервера в строке.'
              : 'One server address per line.',
          child: const NozeltTextField(
            initialValue: 'https://1.1.1.1/dns-query',
            minLines: 2,
            maxLines: 4,
          ),
        ),
        NozeltSettingsField(
          label: ru ? 'Алгоритм кэша' : 'Cache algorithm',
          controlMaxWidth: 360,
          child: NozeltDropdownField<String>(
            value: 'lru',
            onChanged: (_) {},
            items: const [
              DropdownMenuItem(value: 'lru', child: Text('LRU')),
              DropdownMenuItem(value: 'arc', child: Text('ARC')),
            ],
          ),
        ),
        NozeltSettingsField(
          label: ru
              ? 'Параметр с длинным названием для проверки переноса'
              : 'A setting with a longer caption',
          child: const NozeltTextField(initialValue: '4096', enabled: false),
        ),
      ],
    );
  }
}

class NozeltProfileImportShowcase extends StatelessWidget {
  const NozeltProfileImportShowcase({super.key});
  @override
  Widget build(BuildContext context) {
    final ru = _ru(context);
    final android = Theme.of(context).platform == TargetPlatform.android;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NozeltProfileImportActions(
          pasteLabel: ru ? 'Из буфера' : 'From clipboard',
          scanLabel: ru ? 'По QR-коду' : 'Scan QR',
          showQr: android,
          onPaste: () {},
          onScan: () {},
        ),
        const SizedBox(height: NozeltSpacing.xxl),
        NozeltProfileImportActions(
          pasteLabel: ru ? 'Из буфера' : 'From clipboard',
          scanLabel: ru ? 'По QR-коду' : 'Scan QR',
          showQr: android,
          onPaste: null,
        ),
      ],
    );
  }
}

/// Pure UI fixtures shared by Widgetbook and Alchemist. No app providers,
/// profiles, platform channels, storage or native VPN initialization.
class NozeltButtonsShowcase extends StatelessWidget {
  const NozeltButtonsShowcase({super.key});

  @override
  Widget build(BuildContext context) {
    final ru = _ru(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final variant in NozeltButtonVariant.values) ...[
          Text(variant.name, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: NozeltSpacing.sm),
          Wrap(
            spacing: NozeltSpacing.sm,
            runSpacing: NozeltSpacing.sm,
            children: [
              NozeltButton(
                label: ru ? 'Добавить профиль' : 'Add profile',
                onPressed: () {},
                icon: const Icon(Icons.add_rounded),
                variant: variant,
              ),
              NozeltButton(
                label: ru ? 'Недоступно' : 'Disabled',
                onPressed: null,
                variant: variant,
              ),
              NozeltButton(
                label: ru ? 'Сохранение' : 'Saving',
                onPressed: () {},
                loading: true,
                variant: variant,
              ),
            ],
          ),
          const SizedBox(height: NozeltSpacing.xl),
        ],
        Wrap(
          spacing: NozeltSpacing.sm,
          runSpacing: NozeltSpacing.sm,
          children: [
            _StateButton(
              state: WidgetState.hovered,
              label: ru ? 'Наведение' : 'Hover',
            ),
            _StateButton(
              state: WidgetState.focused,
              label: ru ? 'Фокус' : 'Focus',
            ),
            _StateButton(
              state: WidgetState.pressed,
              label: ru ? 'Нажатие' : 'Pressed',
            ),
          ],
        ),
      ],
    );
  }
}

class _StateButton extends StatefulWidget {
  const _StateButton({required this.state, required this.label});
  final WidgetState state;
  final String label;
  @override
  State<_StateButton> createState() => _StateButtonState();
}

class _StateButtonState extends State<_StateButton> {
  late final _states = WidgetStatesController({widget.state});
  @override
  void dispose() {
    _states.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => NozeltButton(
    label: widget.label,
    onPressed: () {},
    statesController: _states,
  );
}

class NozeltFieldsShowcase extends StatelessWidget {
  const NozeltFieldsShowcase({super.key});
  @override
  Widget build(BuildContext context) {
    final ru = _ru(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NozeltTextField(
          label: ru ? 'Название профиля' : 'Profile name',
          hintText: ru ? 'Введите название' : 'Enter a name',
        ),
        const SizedBox(height: NozeltSpacing.lg),
        NozeltTextField(
          label: ru ? 'Заполненное поле' : 'Filled field',
          initialValue: 'https://example.test/subscription',
        ),
        const SizedBox(height: NozeltSpacing.lg),
        NozeltTextField(
          label: ru ? 'Ошибка' : 'Error',
          initialValue: 'example',
          errorText: ru
              ? 'Введите полный адрес, начинающийся с https://'
              : 'Enter a full address starting with https://',
        ),
        const SizedBox(height: NozeltSpacing.lg),
        NozeltTextField(
          label: ru ? 'Недоступно' : 'Disabled',
          initialValue: 'Nozelt',
          enabled: false,
        ),
        const SizedBox(height: NozeltSpacing.lg),
        NozeltTextField(
          label: ru ? 'Только чтение' : 'Read only',
          initialValue: 'Nozelt',
          readOnly: true,
          suffixIcon: const Icon(Icons.lock_outline_rounded),
        ),
        const SizedBox(height: NozeltSpacing.lg),
        NozeltTextField(
          label: ru
              ? 'Домены и поддомены для выбранного профиля маршрутизации'
              : 'Domains and subdomains for the selected routing profile',
          initialValue: 'example.test\n+.example.org',
          minLines: 3,
          maxLines: 6,
          helperText: ru ? 'Одна запись в строке' : 'One entry per line',
        ),
        const SizedBox(height: NozeltSpacing.lg),
        NozeltTextField(
          label: ru ? 'Поиск' : 'Search',
          prefixIcon: const Icon(Icons.search_rounded),
          size: NozeltControlSize.compact,
        ),
      ],
    );
  }
}

class NozeltSwitchesShowcase extends StatefulWidget {
  const NozeltSwitchesShowcase({super.key});
  @override
  State<NozeltSwitchesShowcase> createState() => _NozeltSwitchesShowcaseState();
}

class _NozeltSwitchesShowcaseState extends State<NozeltSwitchesShowcase> {
  var _on = true;
  var _off = false;
  @override
  Widget build(BuildContext context) {
    final ru = _ru(context);
    return NozeltSurface(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          NozeltSwitchTile(
            title: Text(ru ? 'Автоподключение' : 'Auto-connect'),
            secondary: Icon(
              Icons.bolt_rounded,
              color: Theme.of(context).colorScheme.primary,
            ),
            value: _on,
            onChanged: (v) => setState(() => _on = v),
          ),
          const Divider(height: 1),
          NozeltSwitchTile(
            title: Text(
              ru ? 'Запускать вместе с системой' : 'Start with the system',
            ),
            value: _off,
            onChanged: (v) => setState(() => _off = v),
          ),
          const Divider(height: 1),
          NozeltSwitchTile(
            title: Text(ru ? 'Недоступно — включено' : 'Disabled — on'),
            value: true,
            onChanged: null,
          ),
          NozeltSwitchTile(
            title: Text(ru ? 'Недоступно — выключено' : 'Disabled — off'),
            value: false,
            onChanged: null,
          ),
          const Divider(height: 1),
          NozeltSwitchTile(
            title: Text(
              ru
                  ? 'Автоматически подключаться к последнему выбранному серверу при запуске приложения'
                  : 'Automatically connect to the last selected server when the application starts',
            ),
            subtitle: Text(
              ru
                  ? 'Длинная подпись переносится без фиксированной высоты строки.'
                  : 'Long labels wrap without a fixed row height.',
            ),
            value: _on,
            onChanged: (v) => setState(() => _on = v),
          ),
        ],
      ),
    );
  }
}

class NozeltSegmentsShowcase extends StatefulWidget {
  const NozeltSegmentsShowcase({super.key});
  @override
  State<NozeltSegmentsShowcase> createState() => _NozeltSegmentsShowcaseState();
}

class _NozeltSegmentsShowcaseState extends State<NozeltSegmentsShowcase> {
  var _mode = 0;
  @override
  Widget build(BuildContext context) {
    final ru = _ru(context);
    final segments = [
      ButtonSegment(
        value: 0,
        label: Text(ru ? 'По правилам' : 'Rules'),
        icon: const Icon(Icons.alt_route_rounded),
      ),
      ButtonSegment(
        value: 1,
        label: Text(ru ? 'Глобально' : 'Global'),
        icon: const Icon(Icons.public_rounded),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NozeltSegmentedControl(
          segments: segments,
          value: _mode,
          onChanged: (v) => setState(() => _mode = v),
        ),
        const SizedBox(height: NozeltSpacing.lg),
        NozeltSegmentedControl(
          segments: segments,
          value: _mode,
          onChanged: null,
        ),
        const SizedBox(height: NozeltSpacing.lg),
        NozeltSegmentedControl(
          segments: segments,
          value: _mode,
          size: NozeltControlSize.compact,
          onChanged: (v) => setState(() => _mode = v),
        ),
        const SizedBox(height: NozeltSpacing.lg),
        NozeltSegmentedControl(
          segments: [
            ButtonSegment(
              value: 0,
              label: Text(
                ru
                    ? 'Автоматический выбор конфигурации'
                    : 'Automatic configuration selection',
              ),
            ),
            ButtonSegment(
              value: 1,
              label: Text(
                ru
                    ? 'Настроить параметры вручную'
                    : 'Configure parameters manually',
              ),
            ),
          ],
          value: _mode,
          onChanged: (v) => setState(() => _mode = v),
        ),
      ],
    );
  }
}

class NozeltTokensShowcase extends StatelessWidget {
  const NozeltTokensShowcase({super.key});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = context.nozelt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in {
          'primary': scheme.primary,
          'surface': scheme.surface,
          'surfaceContainerHighest': scheme.surfaceContainerHighest,
          'onSurface': scheme.onSurface,
          'onSurfaceVariant': scheme.onSurfaceVariant,
          'success': tokens.success,
          'warning': tokens.warning,
          'error': scheme.error,
        }.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: NozeltSpacing.sm),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: entry.value,
                    border: Border.all(color: scheme.outline),
                  ),
                ),
                const SizedBox(width: NozeltSpacing.md),
                Expanded(child: Text(entry.key)),
              ],
            ),
          ),
        const SizedBox(height: NozeltSpacing.lg),
        Text(
          'Control ${tokens.controlRadius.toInt()} · Card ${tokens.cardRadius.toInt()} · Menu ${tokens.overlayRadius.toInt()}',
        ),
        const SizedBox(height: NozeltSpacing.sm),
        Text(
          'Главная / Dashboard',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        Text(
          'Заголовок раздела / Section',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Text(
          'Основной текст / Body text',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        Text('Подпись / Caption', style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

/// A layout recipe rather than a second implementation of AddProfileScreen.
class NozeltEditorShowcase extends StatelessWidget {
  const NozeltEditorShowcase({super.key});
  @override
  Widget build(BuildContext context) {
    final ru = _ru(context);
    return Scaffold(
      appBar: AppBar(title: Text(ru ? 'Редактор профиля' : 'Profile editor')),
      body: NozeltEditorBody(
        child: ListView(
          padding: const EdgeInsets.all(NozeltSpacing.lg),
          children: [
            NozeltSurface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  NozeltTextField(
                    label: ru ? 'Название' : 'Name',
                    initialValue: ru ? 'Основной профиль' : 'Main profile',
                  ),
                  const SizedBox(height: NozeltSpacing.lg),
                  NozeltTextField(
                    label: ru ? 'Адрес подписки' : 'Subscription URL',
                    hintText: 'https://example.test/subscription',
                  ),
                  const SizedBox(height: NozeltSpacing.lg),
                  NozeltSwitchTile(
                    title: Text(
                      ru
                          ? 'Автоматически обновлять подписку'
                          : 'Automatically update the subscription',
                    ),
                    value: true,
                    onChanged: (_) {},
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: NozeltPageSaveBar(onPressed: () {}, onCancel: () {}),
    );
  }
}
