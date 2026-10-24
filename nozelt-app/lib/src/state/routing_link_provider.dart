import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'engine_provider.dart';
import 'routing_config_controller.dart';

class RoutingLinkCoordinator extends Notifier<void> {
  StreamSubscription<String>? _subscription;
  Future<void> _tail = Future<void>.value();

  @override
  void build() {
    final engine = ref.watch(nozeltEngineProvider);
    _subscription = engine.routingProfileLinks().listen(_enqueue);
    ref.onDispose(() => _subscription?.cancel());
    Future.microtask(() async {
      try {
        final initial = await engine.getInitialRoutingProfileLink();
        if (initial != null && initial.isNotEmpty) _enqueue(initial);
      } catch (_) {
        // Manual paste import remains available if an OEM drops the intent.
      }
    });
  }

  void _enqueue(String link) {
    _tail = _tail.then((_) async {
      if (!ref.mounted) return;
      try {
        await ref.read(routingConfigControllerProvider).importLink(link);
      } catch (_) {
        // Invalid external links never mutate durable routing state.
      }
    });
  }
}

final routingLinkCoordinatorProvider =
    NotifierProvider<RoutingLinkCoordinator, void>(RoutingLinkCoordinator.new);
