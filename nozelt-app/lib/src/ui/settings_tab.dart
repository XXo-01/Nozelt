import 'package:nozelt/nozelt_design_system.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_metadata.dart';
import '../core/app_settings.dart';
import '../l10n/nozelt_l10n.dart';
import '../l10n/user_error.dart';
import '../state/app_settings_provider.dart';
import '../state/engine_provider.dart';
import '../state/routing_config_controller.dart';
import '../state/settings_provider.dart';
import 'always_on_vpn_screen.dart';
import 'diagnostics_screen.dart';
import 'network_settings_screen.dart';

class SettingsTab extends ConsumerWidget {
  const SettingsTab({this.isVisible = true, super.key});

  final bool isVisible;

  Future<void> _startupChange(
    BuildContext context,
    Future<void> Function() change,
  ) async {
    try {
      await change();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.tr('startupFailed'))));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!isVisible) return const SizedBox.shrink();
    final settings = ref.watch(tunSettingsProvider);
    final appSettings = ref.watch(appSettingsProvider);
    final appNotifier = ref.read(appSettingsProvider.notifier);
    final desktop = defaultTargetPlatform == TargetPlatform.windows;

    Widget list(EdgeInsets insets) => ListView(
      key: const PageStorageKey<String>('settings-scroll'),
      physics: desktop
          ? const ClampingScrollPhysics()
          : const BouncingScrollPhysics(),
      padding: desktop ? insets : const EdgeInsets.fromLTRB(20, 18, 20, 124),
      children: [
        NozeltPageHeader(title: context.tr('settings')),
        const SizedBox(height: 24),
        _SettingsSections(
          sections: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                NozeltSectionTitle(context.tr('general')),
                const SizedBox(height: 10),
                NozeltSurface(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      ListTile(
                        leading: Icon(
                          Icons.palette_outlined,
                          color: nozeltIconAccent(context),
                        ),
                        title: Text(context.tr('appearanceTheme')),
                        trailing: _CompactChoice<AppThemePreference>(
                          value: appSettings.themeMode,
                          options: [
                            (
                              AppThemePreference.dark,
                              context.tr('appearanceDark'),
                            ),
                            (
                              AppThemePreference.light,
                              context.tr('appearanceLight'),
                            ),
                            (
                              AppThemePreference.system,
                              context.tr('appearanceSystem'),
                            ),
                          ],
                          onChanged: appNotifier.setThemeMode,
                        ),
                      ),
                      const Divider(height: 1, indent: 60),
                      ListTile(
                        contentPadding: EdgeInsets.fromLTRB(
                          16,
                          desktop ? 0 : 3,
                          10,
                          desktop ? 0 : 3,
                        ),
                        leading: Icon(
                          Icons.translate_rounded,
                          color: nozeltIconAccent(context),
                        ),
                        title: Text(context.tr('language')),
                        trailing: _CompactChoice<String>(
                          value: appSettings.languageCode,
                          options: [
                            ('ru', context.tr('russian')),
                            ('en', context.tr('english')),
                          ],
                          onChanged: appNotifier.setLanguage,
                        ),
                      ),
                      const Divider(height: 1, indent: 60),
                      NozeltSwitchTile(
                        secondary: Icon(
                          Icons.electric_bolt_rounded,
                          color: nozeltIconAccent(context),
                        ),
                        title: Text(context.tr('autoConnect')),
                        value: appSettings.autoConnectEnabled,
                        onChanged: appNotifier.setAutoConnect,
                      ),
                      const Divider(height: 1, indent: 60),
                      if (desktop) ...[
                        NozeltSwitchTile(
                          secondary: Icon(
                            Icons.power_settings_new_rounded,
                            color: nozeltIconAccent(context),
                          ),
                          title: Text(context.tr('startWithWindows')),
                          value: appSettings.startWithWindows,
                          onChanged: (value) => _startupChange(
                            context,
                            () => appNotifier.setStartWithWindows(value),
                          ),
                        ),
                        const Divider(height: 1, indent: 60),
                        NozeltSwitchTile(
                          secondary: Icon(
                            Icons.visibility_off_rounded,
                            color: nozeltIconAccent(context),
                          ),
                          title: Text(context.tr('silentStart')),
                          value: appSettings.silentStart,
                          onChanged: (value) => _startupChange(
                            context,
                            () => appNotifier.setSilentStart(value),
                          ),
                        ),
                        const Divider(height: 1, indent: 60),
                        ListTile(
                          contentPadding: const EdgeInsets.fromLTRB(
                            16,
                            3,
                            10,
                            3,
                          ),
                          leading: Icon(
                            Icons.mouse_rounded,
                            color: nozeltIconAccent(context),
                          ),
                          title: Text(context.tr('trayClick')),
                          trailing: _CompactChoice<TrayClickAction>(
                            value: appSettings.trayClickAction,
                            options: [
                              (
                                TrayClickAction.openWindow,
                                context.tr('trayOpenWindow'),
                              ),
                              (
                                TrayClickAction.toggleTun,
                                context.tr('trayToggleTun'),
                              ),
                            ],
                            onChanged: appNotifier.setTrayClickAction,
                          ),
                        ),
                        const Divider(height: 1, indent: 60),
                      ],
                      ListTile(
                        contentPadding: EdgeInsets.fromLTRB(
                          16,
                          desktop ? 0 : 3,
                          10,
                          desktop ? 0 : 3,
                        ),
                        leading: Icon(
                          Icons.speed_rounded,
                          color: nozeltIconAccent(context),
                        ),
                        title: Text(
                          context.tr('pingInterval'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        minVerticalPadding: 0,
                        visualDensity: VisualDensity.compact,
                        trailing: _pingDropdown(
                          context,
                          ref,
                          appSettings.pingIntervalSeconds,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                NozeltSectionTitle(context.tr('privacy')),
                const SizedBox(height: 10),
                NozeltSurface(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      if (!desktop) ...[
                        _SettingsTile(
                          icon: Icons.lock_rounded,
                          title: context.tr('alwaysOnVpn'),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const AlwaysOnVpnScreen(),
                            ),
                          ),
                        ),
                        const Divider(height: 1, indent: 60),
                      ],
                      _SettingsTile(
                        icon: Icons.health_and_safety_rounded,
                        title: context.tr('diagnostics'),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const DiagnosticsScreen(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                NozeltSectionTitle(context.tr('routing')),
                const SizedBox(height: 10),
                NozeltSurface(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      NozeltSwitchTile(
                        secondary: Icon(
                          Icons.lan_outlined,
                          color: nozeltIconAccent(context),
                        ),
                        title: Text(context.tr('allowLan')),
                        value: settings.allowLan,
                        onChanged: (value) => _applyNetworkChange(
                          context,
                          () => ref
                              .read(routingConfigControllerProvider)
                              .setAllowLan(value),
                        ),
                      ),
                      const Divider(height: 1, indent: 60),
                      NozeltSwitchTile(
                        secondary: Icon(
                          Icons.manage_search_rounded,
                          color: nozeltIconAccent(context),
                        ),
                        title: Text(context.tr('domainSniffer')),
                        value: settings.snifferEnabled,
                        onChanged: (value) => _applyNetworkChange(
                          context,
                          () => ref
                              .read(routingConfigControllerProvider)
                              .setSnifferEnabled(value),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                NozeltSectionTitle(context.tr('networkSettings')),
                const SizedBox(height: 10),
                NozeltSurface(
                  padding: EdgeInsets.zero,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ...[
                        _SettingsTile(
                          icon: Icons.hub_rounded,
                          title: context.tr('tunSettings'),
                          value:
                              '${settings.desktop.stackOverride.isEmpty ? settings.stack.name : settings.desktop.stackOverride} · MTU ${settings.mtu}',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  const NetworkSettingsScreen(dns: false),
                            ),
                          ),
                        ),
                        const Divider(height: 1, indent: 60),
                        _SettingsTile(
                          icon: Icons.dns_rounded,
                          title: context.tr('dnsSettings'),
                          value: settings.dns.mode == 'fake-ip'
                              ? 'Fake-IP'
                              : 'Redir-Host',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  const NetworkSettingsScreen(dns: true),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                NozeltSectionTitle(context.tr('about')),
                const SizedBox(height: 10),
                const _AboutCard(),
              ],
            ),
          ],
        ),
      ],
    );
    return SafeArea(
      bottom: false,
      child: desktop
          ? NozeltPageInsets(builder: (context, insets) => list(insets))
          : list(EdgeInsets.zero),
    );
  }

  Widget _pingDropdown(BuildContext context, WidgetRef ref, int current) {
    const presets = {0, 10, 20, 30, 60, 300};
    return _CompactChoice<int>(
      value: presets.contains(current) ? current : -1,
      options: [
        (0, context.tr('never')),
        for (final seconds in const [10, 20, 30])
          (seconds, context.tr('seconds', {'value': seconds})),
        (60, context.tr('minutes', {'value': 1})),
        (300, context.tr('minutes', {'value': 5})),
        (-1, context.tr('custom')),
      ],
      onChanged: (value) async {
        if (value == -1) {
          await _editCustomPingInterval(context, ref, current);
        } else {
          await ref.read(appSettingsProvider.notifier).setPingInterval(value);
        }
      },
    );
  }

  Future<void> _editCustomPingInterval(
    BuildContext context,
    WidgetRef ref,
    int current,
  ) async {
    final formKey = GlobalKey<FormState>();
    var input = current >= 10 && !{10, 20, 30, 60, 300}.contains(current)
        ? current.toString()
        : '60';
    final result = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.tr('customPingInterval')),
        content: Form(
          key: formKey,
          child: TextFormField(
            initialValue: input,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(suffixText: context.tr('secondsShort')),
            onChanged: (value) => input = value,
            validator: (value) {
              final seconds = int.tryParse(value ?? '');
              return seconds == null || seconds < 10
                  ? context.tr('minimumTenSeconds')
                  : null;
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(context.tr('cancel')),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.pop(dialogContext, int.parse(input));
              }
            },
            child: Text(context.tr('save')),
          ),
        ],
      ),
    );
    if (result != null) {
      await ref.read(appSettingsProvider.notifier).setPingInterval(result);
    }
  }

  Future<void> _applyNetworkChange(
    BuildContext context,
    Future<void> Function() operation,
  ) async {
    try {
      await operation();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(localizedUserError(context.l10n, error))),
      );
    }
  }
}

class _SettingsSections extends StatelessWidget {
  const _SettingsSections({required this.sections});
  final List<Widget> sections;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      Widget column(Iterable<Widget> items) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in items) ...[item, const SizedBox(height: 24)],
        ],
      );
      return Align(
        alignment: Alignment.topLeft,
        // Windows settings use the full shared page column.
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: double.infinity),
          child: column(sections),
        ),
      );
    },
  );
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.value,
  });

  final IconData icon;
  final String title;
  final String? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.symmetric(
      horizontal: 16,
      vertical: Theme.of(context).platform == TargetPlatform.windows ? 0 : 3,
    ),
    leading: Icon(icon, color: nozeltIconAccent(context)),
    title: Text(title),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (value != null)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Tooltip(
              message: value!,
              child: Text(
                value!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        const SizedBox(width: 5),
        Icon(
          Icons.chevron_right_rounded,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ],
    ),
    onTap: onTap,
  );
}

class _CompactChoice<T> extends StatelessWidget {
  const _CompactChoice({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = options
        .where((option) => option.$1 == value)
        .map((option) => option.$2)
        .firstOrNull;
    return NozeltPopupMenuButton<T>(
      tooltip: '',
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final option in options)
          PopupMenuItem<T>(value: option.$1, child: Text(option.$2)),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              selected ?? '',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 5),
            Icon(
              Icons.arrow_drop_down_rounded,
              size: 20,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _AboutCard extends ConsumerWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final versions = ref.watch(engineVersionsProvider);
    return NozeltSurface(
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: Image.asset(
              'assets/branding/nozelt_new_logo.png',
              width: 88,
              height: 88,
              filterQuality: FilterQuality.high,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Nozelt', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 3),
                Text(
                  context.tr('version', {'value': AppMetadata.version}),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                versions.when(
                  data: (value) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _CoreVersionLabel(name: 'Mihomo', version: value.mihomo),
                      _CoreVersionLabel(name: 'Xray', version: value.xray),
                      _CoreVersionLabel(
                        name: 'sing-box',
                        version: value.singBox,
                      ),
                    ],
                  ),
                  loading: () => Text(
                    context.tr('componentsLoading'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  error: (_, _) => Text(
                    context.tr('coreUnavailable'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CoreVersionLabel extends StatelessWidget {
  const _CoreVersionLabel({required this.name, required this.version});

  final String name;
  final String version;

  @override
  Widget build(BuildContext context) => Text(
    '$name $version',
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Theme.of(context).platform == TargetPlatform.windows
          ? Theme.of(context).colorScheme.onSurfaceVariant
          : Theme.of(context).colorScheme.primary,
      height: 1.35,
    ),
  );
}
