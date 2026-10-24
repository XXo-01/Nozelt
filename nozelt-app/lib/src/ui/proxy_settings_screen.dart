import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/geo_ip_service.dart';
import '../core/profile.dart';
import '../core/proxy_node.dart';
import '../l10n/nozelt_l10n.dart';
import '../l10n/user_error.dart';
import '../state/profiles_provider.dart';
import 'design_system/nozelt_tokens.dart';
import 'widgets/country_flag.dart';
import 'widgets/nozelt_ui.dart';

final _proxyIpProvider = FutureProvider.autoDispose.family<String?, String>(
  (ref, server) => const GeoIpService().resolveServerAddress(server),
);

class ProxySettingsScreen extends ConsumerStatefulWidget {
  const ProxySettingsScreen({
    required this.profile,
    required this.node,
    super.key,
  });

  final Profile profile;
  final ProxyNode node;

  @override
  ConsumerState<ProxySettingsScreen> createState() =>
      _ProxySettingsScreenState();
}

class _ProxySettingsScreenState extends ConsumerState<ProxySettingsScreen> {
  late bool _automaticCountry;
  late final bool _initialAutomaticCountry;
  late final String _initialCountryCode;
  late final TextEditingController _countryController;
  late final List<String> _parameterKeys;
  late final Map<String, Object?> _initialValues;
  late final Map<String, String> _initialTexts;
  late final Map<String, TextEditingController> _parameterControllers;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _automaticCountry = widget.node.countryCodeOverride == null;
    _initialAutomaticCountry = _automaticCountry;
    _initialCountryCode = widget.node.countryCodeOverride ?? '';
    _countryController = TextEditingController(text: _initialCountryCode);
    _parameterKeys = _orderedKeys(widget.node.raw);
    _initialValues = {
      for (final key in _parameterKeys) key: widget.node.raw[key],
    };
    _initialTexts = {
      for (final key in _parameterKeys)
        key: _formatParameterValue(widget.node.raw[key]),
    };
    _parameterControllers = {
      for (final key in _parameterKeys)
        key: TextEditingController(text: _initialTexts[key]),
    };
  }

  @override
  void dispose() {
    _countryController.dispose();
    for (final controller in _parameterControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  bool get _hasChanges {
    if (_automaticCountry != _initialAutomaticCountry) return true;
    if (!_automaticCountry &&
        _countryController.text.trim().toUpperCase() != _initialCountryCode) {
      return true;
    }
    return _parameterKeys.any(
      (key) => _parameterControllers[key]!.text != _initialTexts[key],
    );
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final importedIp = _rawIp(node.raw);
    final resolvedIp = importedIp == null
        ? ref.watch(_proxyIpProvider(node.server))
        : null;
    return Scaffold(
      appBar: defaultTargetPlatform == TargetPlatform.windows
          ? NozeltDesktopAppBar(title: Text(context.tr('nodeSettings')))
          : AppBar(
              leading: IconButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              title: Text(context.tr('nodeSettings')),
            ),
      body: NozeltEditorBody(
        child: NozeltPageInsets(
          top: NozeltSpacing.sm,
          builder: (context, insets) => ListView(
            padding: defaultTargetPlatform == TargetPlatform.windows
                ? insets
                : const EdgeInsets.fromLTRB(20, 10, 20, 28),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  CountryFlag(node.flagEmoji, size: 29),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      node.displayName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              NozeltSurface(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    SwitchListTile(
                      contentPadding: const EdgeInsets.fromLTRB(16, 4, 12, 4),
                      secondary: CountryFlag(node.flagEmoji, size: 24),
                      title: Text(context.tr('countryAuto')),
                      value: _automaticCountry,
                      onChanged: (value) {
                        setState(() {
                          _automaticCountry = value;
                          if (!value &&
                              _countryController.text.trim().isEmpty) {
                            _countryController.text = node.countryCode ?? '';
                          }
                        });
                      },
                    ),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                      child: _automaticCountry
                          ? const SizedBox.shrink()
                          : Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                              child: TextField(
                                controller: _countryController,
                                onChanged: (_) => setState(() {}),
                                textCapitalization:
                                    TextCapitalization.characters,
                                maxLength: 2,
                                decoration: InputDecoration(
                                  labelText: context.tr('countryCode'),
                                  hintText: 'FI',
                                  helperText: context.tr('countryCodeHint'),
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              // Windows uses the same section title as every other page.
              if (defaultTargetPlatform == TargetPlatform.windows)
                NozeltSectionTitle(context.tr('technicalParameters'))
              else
                Text(
                  context.tr('technicalParameters'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              const SizedBox(height: 10),
              NozeltSurface(
                child: Column(
                  children: [
                    for (
                      var index = 0;
                      index < _parameterKeys.length;
                      index++
                    ) ...[
                      _ParameterEditor(
                        label: _detailLabel(context, _parameterKeys[index]),
                        controller:
                            _parameterControllers[_parameterKeys[index]]!,
                        originalValue: _initialValues[_parameterKeys[index]],
                        onChanged: () => setState(() {}),
                      ),
                      if (index != _parameterKeys.length - 1)
                        const SizedBox(height: 14),
                    ],
                    if (importedIp == null) ...[
                      const SizedBox(height: 14),
                      _ReadOnlyParameter(
                        label: context.tr('resolvedIpAddress'),
                        value: resolvedIp!.when(
                          data: (value) => value ?? context.tr('unavailable'),
                          loading: () => '…',
                          error: (_, _) => context.tr('unavailable'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: defaultTargetPlatform == TargetPlatform.windows
          ? NozeltPageSaveBar(
              saving: _saving,
              onPressed: _hasChanges ? _save : null,
              onCancel: () => Navigator.of(context).pop(),
            )
          : Material(
              color: Theme.of(context).scaffoldBackgroundColor,
              elevation: 12,
              child: SafeArea(
                top: false,
                minimum: const EdgeInsets.fromLTRB(20, 10, 20, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _saving
                            ? null
                            : () => Navigator.of(context).pop(),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 52),
                          side: BorderSide(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: Text(context.tr('cancel')),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _saving || !_hasChanges ? null : _save,
                        child: _saving
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(context.tr('save')),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Future<void> _save() async {
    final countryCode = _countryController.text.trim().toUpperCase();
    if (!_automaticCountry && !RegExp(r'^[A-Z]{2}$').hasMatch(countryCode)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.tr('countryCodeHint'))));
      return;
    }

    final raw = <String, dynamic>{};
    try {
      for (final key in _parameterKeys) {
        raw[key] = _parseParameterValue(
          key,
          _parameterControllers[key]!.text,
          _initialValues[key],
        );
      }
    } on _InvalidParameter catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr('invalidProxyParameter', {
              'field': _detailLabel(context, error.key),
            }),
          ),
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.tr('changeProxyParameters')),
        content: Text(context.tr('confirmProxyParametersChange')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.tr('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.tr('change')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _saving = true);
    try {
      await ref
          .read(profilesProvider.notifier)
          .updateNodeDetails(
            widget.profile.id,
            widget.node.name,
            raw,
            _automaticCountry ? null : countryCode,
          );
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      final message = error is FormatException
          ? context.tr('invalidProxyParameters')
          : localizedUserError(context.l10n, error);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  List<String> _orderedKeys(Map<String, dynamic> raw) {
    const firstKeys = [
      'name',
      'type',
      'server',
      'port',
      'ip',
      'ports',
      'hop-interval',
      'username',
      'password',
      'uuid',
      'cipher',
      'network',
      'tls',
      'servername',
      'sni',
      'skip-cert-verify',
      'client-fingerprint',
      'fingerprint',
      'flow',
      'obfs',
      'obfs-password',
      'obfs-min-packet-size',
      'obfs-max-packet-size',
      'nozelt-auto-interval',
      'nozelt-auto-url',
      'nozelt-native-config',
    ];
    return [
      for (final key in firstKeys)
        if (raw.containsKey(key)) key,
      for (final key in raw.keys)
        if (!firstKeys.contains(key)) key,
    ];
  }

  String _detailLabel(BuildContext context, String key) {
    final labelKey = switch (key) {
      'name' => 'proxyName',
      'type' => 'protocol',
      'server' => 'server',
      'port' => 'port',
      'ip' => 'ipAddress',
      'ports' => 'ports',
      'hop-interval' => 'hopInterval',
      'network' => 'transport',
      'flow' => 'flow',
      'obfs' => 'obfuscation',
      'password' => 'password',
      'username' => 'username',
      'cipher' => 'cipher',
      'uuid' => 'uuid',
      'tls' => 'tls',
      'udp' => 'udp',
      'skip-cert-verify' => 'certificateVerification',
      'obfs-password' => 'obfuscationPassword',
      'obfs-min-packet-size' => 'obfuscationMinPacket',
      'obfs-max-packet-size' => 'obfuscationMaxPacket',
      'servername' || 'sni' => 'sni',
      'client-fingerprint' || 'fingerprint' => 'fingerprint',
      'nozelt-auto-interval' => 'proxyPingInterval',
      'nozelt-auto-url' => 'proxyPingUrl',
      'nozelt-native-config' => 'proxyConfig',
      _ => null,
    };
    return labelKey == null ? key : context.tr(labelKey);
  }

  static String _formatParameterValue(Object? value) {
    if (value is String) return value;
    if (value == null) return 'null';
    if (value is Map || value is List) {
      return const JsonEncoder.withIndent('  ').convert(value);
    }
    return value.toString();
  }

  Object? _parseParameterValue(String key, String text, Object? original) {
    if (original is String) return text;
    final trimmed = text.trim();
    if (original is bool) {
      if (trimmed.toLowerCase() == 'true') return true;
      if (trimmed.toLowerCase() == 'false') return false;
      throw _InvalidParameter(key);
    }
    if (original is int) {
      return int.tryParse(trimmed) ?? (throw _InvalidParameter(key));
    }
    if (original is double) {
      return double.tryParse(trimmed) ?? (throw _InvalidParameter(key));
    }
    if (original is Map || original is List) {
      try {
        final decoded = jsonDecode(text);
        if ((original is Map && decoded is! Map) ||
            (original is List && decoded is! List)) {
          throw const FormatException();
        }
        return decoded;
      } catch (_) {
        throw _InvalidParameter(key);
      }
    }
    if (original == null) {
      try {
        return jsonDecode(text);
      } catch (_) {
        return text;
      }
    }
    return text;
  }
}

String? _rawIp(Map<String, dynamic> raw) {
  for (final entry in raw.entries) {
    if (entry.key.toLowerCase() != 'ip') continue;
    final value = entry.value?.toString().trim();
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

class _InvalidParameter implements Exception {
  const _InvalidParameter(this.key);

  final String key;
}

class _ParameterEditor extends StatelessWidget {
  const _ParameterEditor({
    required this.label,
    required this.controller,
    required this.originalValue,
    required this.onChanged,
  });

  final String label;
  final TextEditingController controller;
  final Object? originalValue;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final structured = originalValue is Map || originalValue is List;
    final numeric = originalValue is num;
    return TextField(
      controller: controller,
      onChanged: (_) => onChanged(),
      minLines: structured ? 5 : 1,
      maxLines: structured ? 14 : 4,
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : TextInputType.multiline,
      autocorrect: false,
      enableSuggestions: false,
      style: TextStyle(
        fontFamily: structured ? 'monospace' : null,
        fontSize: structured ? 13 : 15,
      ),
      decoration: InputDecoration(
        labelText: label,
        alignLabelWithHint: structured,
      ),
    );
  }
}

class _ReadOnlyParameter extends StatelessWidget {
  const _ReadOnlyParameter({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => InputDecorator(
    decoration: InputDecoration(
      labelText: label,
      suffixIcon: const Icon(Icons.lock_outline_rounded, size: 18),
    ),
    child: SelectableText(value),
  );
}
