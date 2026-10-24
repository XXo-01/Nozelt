import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final processIconCacheProvider = Provider((ref) => ProcessIconCache());

/// Bounded, session-only cache. Missing processes are retried after 30 seconds;
/// periodic traffic snapshots never reread an EXE or duplicate pending requests.
class ProcessIconCache {
  static const channel = MethodChannel('dev.nozelt.nozelt/windows_shell');
  final _entries = <String, _IconEntry>{};

  Future<Uint8List?> load(String process) {
    final key = process.trim().toLowerCase();
    if (key.isEmpty || key == '—') return Future.value();
    final entry = _entries.remove(key);
    if (entry != null && DateTime.now().isBefore(entry.expires)) {
      _entries[key] = entry;
      return entry.bytes;
    }
    final next = _IconEntry();
    next.bytes = _read(key).then((bytes) {
      next.expires = DateTime.now().add(
        bytes == null
            ? const Duration(seconds: 30)
            : const Duration(minutes: 30),
      );
      return bytes;
    });
    _entries[key] = next;
    while (_entries.length > 128) {
      _entries.remove(_entries.keys.first);
    }
    return next.bytes;
  }

  Future<Uint8List?> _read(String process) async {
    try {
      return await channel.invokeMethod<Uint8List>('getProcessIcon', process);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

class _IconEntry {
  late Future<Uint8List?> bytes;
  DateTime expires = DateTime.now().add(const Duration(minutes: 1));
}

class ProcessIcon extends ConsumerWidget {
  const ProcessIcon(this.process, {super.key});
  final String process;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fallback = Icon(
      Icons.apps_rounded,
      size: 23,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return SizedBox(
      width: 32,
      height: 32,
      child: FutureBuilder<Uint8List?>(
        future: ref.watch(processIconCacheProvider).load(process),
        builder: (context, snapshot) => snapshot.data == null
            ? fallback
            : Image.memory(
                snapshot.data!,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                filterQuality: FilterQuality.high,
                errorBuilder: (_, _, _) => fallback,
              ),
      ),
    );
  }
}
