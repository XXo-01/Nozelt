import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/nozelt_engine.dart';
import '../core/profile.dart';
import '../core/vpn_core.dart';
import '../l10n/nozelt_l10n.dart';
import '../l10n/user_error.dart';
import '../state/engine_provider.dart';
import '../state/profiles_provider.dart';
import 'widgets/auto_update_interval_field.dart';
import 'widgets/core_selector.dart';
import 'package:nozelt/nozelt_design_system.dart';
import 'profile_import_payload.dart';
import 'profile_qr_scanner_screen.dart';

enum _AddMode { subscription, links, file }

/// Add a profile via one of three paths: subscription URL, pasted links, or an
/// imported YAML file. Parsing/downloading runs async with a progress state so
/// the UI never blocks.
class AddProfileScreen extends ConsumerStatefulWidget {
  const AddProfileScreen({super.key});

  @override
  ConsumerState<AddProfileScreen> createState() => _AddProfileScreenState();
}

class _AddProfileScreenState extends ConsumerState<AddProfileScreen> {
  static const int _maxImportBytes = 16 * 1024 * 1024;
  static const int _maxPastedCharacters = 4 * 1024 * 1024;
  _AddMode _mode = _AddMode.subscription;
  final _nameCtrl = TextEditingController();
  final _linksCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  int _autoUpdateMinutes = 24 * 60;
  ProfileCoreMode _coreMode = ProfileCoreMode.automatic;
  VpnCore _manualCore = VpnCore.mihomo;
  String? _fileName;
  String? _fileContent;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _linksCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final desktop = theme.platform == TargetPlatform.windows;
    return Scaffold(
      appBar: desktop
          ? NozeltDesktopAppBar(title: Text(context.tr('addProfileTitle')))
          : AppBar(title: Text(context.tr('addProfileTitle'))),
      body: NozeltEditorBody(
        child: AbsorbPointer(
          absorbing: _busy,
          child: NozeltPageInsets(
            top: NozeltSpacing.sm,
            builder: (context, insets) => ListView(
              padding: desktop ? insets : const EdgeInsets.all(16),
              children: [
                NozeltProfileImportActions(
                  pasteLabel: context.tr('importFromClipboard'),
                  scanLabel: context.tr('importFromQr'),
                  onPaste: _busy ? null : _importClipboard,
                  onScan: _busy ? null : _scanQr,
                  showQr: !kIsWeb && theme.platform == TargetPlatform.android,
                ),
                const SizedBox(height: NozeltSpacing.lg),
                NozeltSegmentedControl<_AddMode>(
                  segments: [
                    ButtonSegment(
                      value: _AddMode.subscription,
                      label: Text(context.tr('subscription')),
                      icon: const Icon(Icons.cloud_sync),
                    ),
                    ButtonSegment(
                      value: _AddMode.links,
                      label: Text(context.tr('links')),
                      icon: const Icon(Icons.link),
                    ),
                    ButtonSegment(
                      value: _AddMode.file,
                      label: Text(context.tr('file')),
                      icon: const Icon(Icons.description),
                    ),
                  ],
                  value: _mode,
                  onChanged: (mode) => setState(() {
                    _mode = mode;
                    _error = null;
                  }),
                ),
                const SizedBox(height: 16),
                NozeltTextField(
                  controller: _nameCtrl,
                  inputFormatters: [
                    LengthLimitingTextInputFormatter(maxProfileNameRunes),
                  ],
                  label: context.tr('profileNameOptional'),
                ),
                const SizedBox(height: 16),
                ..._modeFields(),
                const SizedBox(height: 18),
                CoreSelector(
                  showAutomaticHint: false,
                  mode: _coreMode,
                  manualCore: _manualCore,
                  onModeChanged: (value) => setState(() => _coreMode = value),
                  onManualCoreChanged: (value) =>
                      setState(() => _manualCore = value),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
                const SizedBox(height: 24),
                Align(
                  alignment: Alignment.centerRight,
                  child: SizedBox(
                    width: desktop ? 220 : double.infinity,
                    child: NozeltButton(
                      onPressed: _submit,
                      loading: _busy,
                      icon: const Icon(Icons.add),
                      label: _busy
                          ? context.tr('adding')
                          : context.tr('addProfile'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _modeFields() {
    switch (_mode) {
      case _AddMode.subscription:
        return [
          NozeltTextField(
            controller: _urlCtrl,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            label: context.tr('subscriptionUrl'),
          ),
          const SizedBox(height: 12),
          AutoUpdateIntervalField(
            valueMinutes: _autoUpdateMinutes,
            onChanged: (value) => _autoUpdateMinutes = value,
          ),
        ];
      case _AddMode.links:
        return [
          NozeltTextField(
            controller: _linksCtrl,
            autocorrect: false,
            enableSuggestions: false,
            minLines: 4,
            maxLines: 10,
            label: context.tr('proxyLinks'),
          ),
        ];
      case _AddMode.file:
        return [
          NozeltButton(
            variant: NozeltButtonVariant.secondary,
            onPressed: _pickFile,
            icon: const Icon(Icons.upload_file),
            label: _fileName ?? context.tr('pickYaml'),
          ),
        ];
    }
  }

  Future<void> _importClipboard() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? text;
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (_) {
      if (mounted) setState(() => _error = context.tr('importClipboardError'));
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) await _importText(text);
  }

  Future<void> _scanQr() async {
    if (_busy) return;
    final text = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ProfileQrScannerScreen()),
    );
    if (mounted && text != null) await _importText(text);
  }

  Future<void> _importText(String? text) async {
    if (_busy) return;
    try {
      final payload = ProfileImportPayload.parse(text);
      setState(() {
        _error = null;
        if (payload.kind == ProfileImportKind.subscription) {
          _mode = _AddMode.subscription;
          _urlCtrl.text = payload.text;
        } else {
          _mode = _AddMode.links;
          _linksCtrl.text = payload.text;
        }
      });
      await _submit();
    } on ProfileImportException catch (error) {
      if (mounted) setState(() => _error = context.tr(error.messageKey));
    }
  }

  Future<void> _pickFile() async {
    try {
      final file = await ref.read(nozeltEngineProvider).pickConfigFile();
      if (file == null) return;
      if (file.bytes.length > _maxImportBytes) {
        if (mounted) setState(() => _error = context.tr('fileTooLarge'));
        return;
      }
      if (!mounted) return;
      setState(() {
        _fileName = file.name;
        _fileContent = utf8.decode(file.bytes, allowMalformed: true);
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e is NozeltEngineException && e.code == 'file_too_large'
              ? context.tr('fileTooLarge')
              : context.tr('readFileError');
        });
      }
    }
  }

  Future<void> _submit() async {
    if (_busy) return;
    final l10n = context.l10n;
    setState(() {
      _busy = true;
      _error = null;
    });
    final notifier = ref.read(profilesProvider.notifier);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      switch (_mode) {
        case _AddMode.subscription:
          final url = _urlCtrl.text.trim();
          if (url.isEmpty) throw _Invalid(context.tr('enterSubscription'));
          await notifier.addFromSubscription(
            _nameCtrl.text.trim(),
            url,
            fallbackName: _hostOf(url),
            autoUpdateMinutes: _autoUpdateMinutes,
            coreMode: _coreMode,
            manualCore: _manualCore,
          );
        case _AddMode.links:
          final links = _linksCtrl.text.trim();
          if (links.isEmpty) throw _Invalid(context.tr('pasteLink'));
          if (links.length > _maxPastedCharacters) {
            throw _Invalid(context.tr('proxyDataTooLarge'));
          }
          await notifier.addFromLinks(
            _resolveName(fallback: context.tr('manual')),
            links,
            coreMode: _coreMode,
            manualCore: _manualCore,
          );
        case _AddMode.file:
          final content = _fileContent;
          if (content == null) throw _Invalid(context.tr('pickFileFirst'));
          await notifier.addFromFile(
            _resolveName(
              fallback:
                  _fileName ??
                  (context.l10n.isRussian ? 'Импортированный' : 'Imported'),
            ),
            content,
            coreMode: _coreMode,
            manualCore: _manualCore,
          );
      }
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.text('profileAdded'))),
      );
      navigator.pop();
    } catch (e) {
      if (mounted) {
        setState(
          () =>
              _error = e is _Invalid ? e.message : localizedUserError(l10n, e),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _resolveName({required String fallback}) {
    final n = _nameCtrl.text.trim();
    return n.isEmpty ? fallback : n;
  }

  String _hostOf(String url) {
    try {
      final h = Uri.parse(url).host;
      return h.isEmpty ? context.tr('subscription') : h;
    } catch (_) {
      return context.tr('subscription');
    }
  }
}

/// A validation error carrying a user-facing message (distinguished from
/// unexpected exceptions so we can show the clean text).
class _Invalid implements Exception {
  const _Invalid(this.message);
  final String message;
}
