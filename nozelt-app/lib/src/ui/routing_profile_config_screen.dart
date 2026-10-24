import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/routing_profile.dart';
import '../l10n/nozelt_l10n.dart';
import '../l10n/user_error.dart';
import '../state/routing_config_controller.dart';
import '../state/routing_profiles_provider.dart';
import 'design_system/nozelt_tokens.dart';
import 'widgets/nozelt_ui.dart';

class RoutingProfileConfigScreen extends ConsumerStatefulWidget {
  const RoutingProfileConfigScreen({super.key});

  @override
  ConsumerState<RoutingProfileConfigScreen> createState() =>
      _RoutingProfileConfigScreenState();
}

class _RoutingProfileConfigScreenState
    extends ConsumerState<RoutingProfileConfigScreen> {
  late final TextEditingController _controller = TextEditingController(
    text: ref.read(routingProfilesProvider).active.encodeConfig(),
  );
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: defaultTargetPlatform == TargetPlatform.windows
        ? NozeltDesktopAppBar(title: Text(context.tr('routingConfig')))
        : AppBar(title: Text(context.tr('routingConfig'))),
    body: NozeltEditorBody(
      child: SafeArea(
        top: false,
        child: NozeltPageInsets(
          top: NozeltSpacing.sm,
          bottom: NozeltSpacing.xxl,
          builder: (context, insets) => Padding(
            padding: defaultTargetPlatform == TargetPlatform.windows
                ? insets
                : const EdgeInsets.fromLTRB(20, 12, 20, 18),
            child: Column(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    expands: true,
                    minLines: null,
                    maxLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                    decoration: InputDecoration(
                      hintText: context.tr('routingConfigHint'),
                      alignLabelWithHint: true,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _copyConfig,
                        icon: const Icon(Icons.copy_rounded),
                        label: Text(context.tr('copyConfig')),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _copyLink,
                        icon: const Icon(Icons.link_rounded),
                        label: Text(context.tr('copyLink')),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: SizedBox(
                    width: defaultTargetPlatform == TargetPlatform.windows
                        ? 220
                        : double.infinity,
                    child: FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: _saving
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_rounded),
                      label: Text(context.tr('save')),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> _copyConfig() async {
    await Clipboard.setData(ClipboardData(text: _controller.text));
    if (mounted) _showCopied();
  }

  Future<void> _copyLink() async {
    try {
      final current = ref.read(routingProfilesProvider).active;
      final parsed = RoutingProfile.decodeConfig(
        _controller.text,
        id: current.id,
      );
      await Clipboard.setData(ClipboardData(text: parsed.encodeShareLink()));
      if (mounted) _showCopied();
    } catch (_) {
      if (mounted) _showInvalid();
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref
          .read(routingConfigControllerProvider)
          .replaceActiveFromConfig(_controller.text);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is FormatException
                ? context.tr('invalidRoutingConfig')
                : localizedUserError(context.l10n, error),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showCopied() => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(context.tr('copied'))));

  void _showInvalid() => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(context.tr('invalidRoutingConfig'))));
}
