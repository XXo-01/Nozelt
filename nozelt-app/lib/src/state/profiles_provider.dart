import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/nozelt_engine.dart';
import '../core/profile.dart';
import '../core/proxy_marks.dart';
import '../core/proxy_node.dart';
import '../core/runtime_rollback.dart';
import '../core/subscription_client.dart';
import '../core/vpn_core.dart';
import '../data/profile_store.dart';
import 'engine_provider.dart';

/// Injectable persistence boundary. Production keeps the encrypted Android
/// store, while transaction tests can model write failures without touching a
/// real app directory or platform channel.
final profileStoreProvider = Provider<ProfileStore>(
  (ref) => const ProfileStore(),
);

final subscriptionClientProvider = Provider<SubscriptionClient>(
  (ref) => SubscriptionClient(
    hwidLoader: () => ref.read(nozeltEngineProvider).getSubscriptionHwid(),
  ),
);

class _ResolvedSubscription {
  const _ResolvedSubscription({
    required this.document,
    required this.parsed,
    required this.userAgent,
  });

  final SubscriptionDocument document;
  final ParsedSubscription parsed;
  final String userAgent;

  SubscriptionMetadata get metadata => parsed.metadata.merge(document.metadata);
}

/// Owns the profiles list + active selection, persisted via [ProfileStore].
///
/// Async because the initial load is file I/O. All mutations parse (Go) and/or
/// download (Dart http) off the UI thread, then persist atomically.
class ProfilesNotifier extends AsyncNotifier<ProfilesState> {
  Future<void> _mutationTail = Future<void>.value();
  Future<void>? _staleRefreshOperation;
  String? _notificationNodeIdentity;

  @override
  Future<ProfilesState> build() async {
    final loaded = await ref.read(profileStoreProvider).load();
    _notificationNodeIdentity = _notificationIdentity(loaded);
    return loaded;
  }

  ProfileStore get _store => ref.read(profileStoreProvider);
  SubscriptionClient get _sub => ref.read(subscriptionClientProvider);

  Future<_ResolvedSubscription> _downloadAndDetect({
    required String url,
    required ProfileCoreMode coreMode,
    required VpnCore manualCore,
    String? explicitUserAgent,
    String? resolvedUserAgent,
    bool forceCoreRepresentation = false,
  }) async {
    final explicit = explicitUserAgent?.trim();
    final resolved = resolvedUserAgent?.trim();
    final candidates = <String>[];

    void addCandidate(String? value) {
      final normalized = value?.trim();
      if (normalized == null ||
          normalized.isEmpty ||
          candidates.contains(normalized)) {
        return;
      }
      candidates.add(normalized);
    }

    if (explicit != null && explicit.isNotEmpty) {
      addCandidate(explicit);
    } else if (coreMode == ProfileCoreMode.manual || forceCoreRepresentation) {
      addCandidate(SubscriptionClient.userAgentForCore(manualCore));
      // A provider may ignore a core-specific User-Agent but still expose a
      // generic link list. The selected core's builder can translate that
      // representation, so retain a compatible fallback.
      addCandidate(SubscriptionClient.defaultUserAgent);
    } else if (resolved != null && resolved.isNotEmpty) {
      // Re-parse the negotiated representation on every refresh. If the
      // provider changes its format, [suggestedCore] changes with it.
      addCandidate(resolved);
    } else {
      // Legacy/new automatic profiles negotiate once. Native full documents
      // outrank flattened Clash link lists because balancers and observatory
      // rules cannot be reconstructed after flattening.
      addCandidate(SubscriptionClient.xrayUserAgent);
      addCandidate(SubscriptionClient.singBoxUserAgent);
      addCandidate(SubscriptionClient.defaultUserAgent);
    }

    _ResolvedSubscription? singBoxCandidate;
    _ResolvedSubscription? mihomoCandidate;
    Object? lastError;
    StackTrace? lastStackTrace;
    for (final userAgent in candidates) {
      try {
        final document = await _sub.downloadDocument(url, userAgent: userAgent);
        if (!ref.mounted) {
          throw StateError('Profiles provider was disposed during download.');
        }
        final parsed = await ref
            .read(nozeltEngineProvider)
            .parseSubscriptionDocument(document.content);
        if (!ref.mounted) {
          throw StateError('Profiles provider was disposed during import.');
        }
        final candidate = _ResolvedSubscription(
          document: document,
          parsed: parsed,
          userAgent: userAgent,
        );
        if (kDebugMode) {
          debugPrint(
            'subscription format detected: ${parsed.suggestedCore.wireName}',
          );
        }

        if (explicit != null ||
            coreMode == ProfileCoreMode.manual ||
            forceCoreRepresentation ||
            (resolved != null && resolved.isNotEmpty)) {
          return candidate;
        }
        switch (parsed.suggestedCore) {
          case VpnCore.xray:
            return candidate;
          case VpnCore.singBox:
            singBoxCandidate ??= candidate;
            break;
          case VpnCore.mihomo:
            // Prefer the actual Clash request over a generic link list
            // returned to another client's User-Agent.
            if (mihomoCandidate == null ||
                userAgent == SubscriptionClient.defaultUserAgent) {
              mihomoCandidate = candidate;
            }
            break;
        }
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
      }
    }
    final detected = singBoxCandidate ?? mihomoCandidate;
    if (detected != null) return detected;
    if (lastError != null) {
      Error.throwWithStackTrace(lastError, lastStackTrace!);
    }
    throw const SubscriptionException(
      'Subscription contained no proxies.',
      l10nKey: 'noValidProxies',
    );
  }

  Profile _mergeSubscriptionRefresh(
    Profile current,
    _ResolvedSubscription resolved, {
    String? explicitName,
    int? autoUpdateMinutes,
    ProfileCoreMode? coreMode,
    VpnCore? manualCore,
  }) {
    final nodes = resolved.parsed.nodes;
    final mergedNodes = inheritProxyMetadata(current.nodes, nodes);
    // Pinned and deleted servers stay so after a refresh; servers that left
    // the subscription drop out of both sets.
    final pinned = carryNodeMarks(
      current.pinnedNodeNames,
      current.nodes,
      mergedNodes,
    );
    final deleted = carryNodeMarks(
      current.deletedNodeNames,
      current.nodes,
      mergedNodes,
    );
    final selectedStillExists = mergedNodes.any(
      (node) => node.name == current.effectiveSelectedNodeName,
    );
    final metadata = resolved.metadata;
    final providerName = metadata.title;
    final nextName = explicitName != null
        ? normalizeProfileName(explicitName)
        : providerName != null
        ? normalizeProfileName(providerName)
        : current.name;
    return current.copyWith(
      name: nextName,
      nameCustomized: explicitName != null
          ? true
          : providerName != null
          ? false
          : current.nameCustomized,
      nodes: mergedNodes,
      pinnedNodeNames: pinned,
      deletedNodeNames: deleted,
      providerRouting: resolved.parsed.providerRouting,
      updatedAt: DateTime.now(),
      autoUpdateMinutes: autoUpdateMinutes,
      subscriptionMetadata: metadata.isEmpty ? null : metadata,
      clearSubscriptionMetadata: metadata.isEmpty,
      resolvedUserAgent: resolved.userAgent,
      topologyRevision: current.topologyRevision + 1,
      detectedCore: resolved.parsed.suggestedCore,
      coreMode: coreMode,
      manualCore: manualCore,
      // The Nozelt auto server stays selected; it re-evaluates the new list.
      selectedNodeName: current.autoSelected
          ? Profile.nozeltAutoId
          : selectedStillExists
          ? current.effectiveSelectedNodeName
          : (mergedNodes.isEmpty ? null : mergedNodes.first.name),
      autoPickName: selectedStillExists
          ? current.effectiveSelectedNodeName
          : (mergedNodes.isEmpty ? null : mergedNodes.first.name),
    );
  }

  ProfilesState get _current {
    final current = state.value;
    if (current != null) return current;
    throw StateError('Profiles are not available for modification.');
  }

  String _newId() =>
      'p_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(0x7fffffff)}';

  Future<void> _persist(ProfilesState next) async {
    final store = _store;
    await store.save(next);
    if (!ref.mounted) {
      throw StateError('Profiles provider was disposed during persistence.');
    }
    state = AsyncData(next);
    _syncActiveNotification(next);
  }

  Future<void> _add(Profile profile) => _serialized(() async {
    final cur = _current;
    // Auto-activate the very first profile so the user does not have to.
    final activeId = cur.profiles.isEmpty ? profile.id : cur.activeId;
    await _persist(
      cur.copyWith(profiles: [...cur.profiles, profile], activeId: activeId),
    );
  });

  /// Manual profile: the textarea may hold one or many share links. Parsing is
  /// delegated to the Go convert engine (same path as a plain subscription).
  Future<Profile> addFromLinks(
    String name,
    String linksText, {
    ProfileCoreMode coreMode = ProfileCoreMode.automatic,
    VpnCore? manualCore,
  }) async {
    final parsed = await ref
        .read(nozeltEngineProvider)
        .parseSubscriptionDocument(linksText);
    if (!ref.mounted) {
      throw StateError('Profiles provider was disposed during import.');
    }
    final nodes = parsed.nodes;
    if (nodes.isEmpty) {
      throw const SubscriptionException(
        'No valid proxies found in the links.',
        l10nKey: 'noValidProxies',
      );
    }
    final profile = Profile(
      id: _newId(),
      name: normalizeProfileName(name),
      type: ProfileType.manual,
      // Parsed nodes already contain everything required to reconnect. Do not
      // keep a second plaintext copy of credential-bearing share links.
      source: '',
      nodes: nodes,
      providerRouting: parsed.providerRouting,
      updatedAt: DateTime.now(),
      selectedNodeName: nodes.first.name,
      coreMode: coreMode,
      manualCore: manualCore ?? parsed.suggestedCore,
      detectedCore: parsed.suggestedCore,
    );
    await _add(profile);
    return profile;
  }

  /// Subscription profile: download (Dart) → parse (Go) → nodes.
  Future<Profile> addFromSubscription(
    String name,
    String url, {
    String? fallbackName,
    String? userAgent,
    int autoUpdateMinutes = 24 * 60,
    ProfileCoreMode coreMode = ProfileCoreMode.automatic,
    VpnCore? manualCore,
  }) async {
    final resolved = await _downloadAndDetect(
      url: url,
      coreMode: coreMode,
      manualCore: manualCore ?? VpnCore.mihomo,
      explicitUserAgent: userAgent,
      forceCoreRepresentation: coreMode == ProfileCoreMode.manual,
    );
    final document = resolved.document;
    final parsed = resolved.parsed;
    final nodes = parsed.nodes;
    if (nodes.isEmpty) {
      throw const SubscriptionException(
        'Subscription contained no proxies.',
        l10nKey: 'noValidProxies',
      );
    }
    final metadata = parsed.metadata.merge(document.metadata);
    final explicitName = name.trim();
    final inferredName =
        metadata.title ?? fallbackName ?? _subscriptionHost(url);
    final profile = Profile(
      id: _newId(),
      name: normalizeProfileName(
        explicitName.isEmpty ? inferredName : explicitName,
      ),
      type: ProfileType.subscription,
      source: url,
      nodes: nodes,
      providerRouting: parsed.providerRouting,
      updatedAt: DateTime.now(),
      autoUpdateMinutes: autoUpdateMinutes,
      userAgent: userAgent,
      resolvedUserAgent: resolved.userAgent,
      subscriptionMetadata: metadata.isEmpty ? null : metadata,
      nameCustomized: explicitName.isNotEmpty,
      selectedNodeName: nodes.first.name,
      coreMode: coreMode,
      manualCore: manualCore ?? parsed.suggestedCore,
      detectedCore: parsed.suggestedCore,
    );
    await _add(profile);
    return profile;
  }

  /// Imported Clash/mihomo YAML file content.
  Future<Profile> addFromFile(
    String name,
    String yamlContent, {
    ProfileCoreMode coreMode = ProfileCoreMode.automatic,
    VpnCore? manualCore,
  }) async {
    final parsed = await ref
        .read(nozeltEngineProvider)
        .parseSubscriptionDocument(yamlContent);
    if (!ref.mounted) {
      throw StateError('Profiles provider was disposed during import.');
    }
    final nodes = parsed.nodes;
    if (nodes.isEmpty) {
      throw const SubscriptionException(
        'File contained no proxies.',
        l10nKey: 'noValidProxies',
      );
    }
    final profile = Profile(
      id: _newId(),
      name: normalizeProfileName(name),
      type: ProfileType.file,
      // Imported YAML can contain every proxy secret; raw node maps are the
      // source of truth after parsing, so avoid persisting a duplicate copy.
      source: '',
      nodes: nodes,
      providerRouting: parsed.providerRouting,
      updatedAt: DateTime.now(),
      selectedNodeName: nodes.first.name,
      coreMode: coreMode,
      manualCore: manualCore ?? parsed.suggestedCore,
      detectedCore: parsed.suggestedCore,
    );
    await _add(profile);
    return profile;
  }

  /// Re-downloads and re-parses a subscription profile in place.
  Future<void> refresh(String id) async {
    final snapshot = _find(id);
    if (snapshot == null || !snapshot.isSubscription) return;
    final resolved = await _downloadAndDetect(
      url: snapshot.source,
      coreMode: snapshot.coreMode,
      manualCore: snapshot.manualCore,
      explicitUserAgent: snapshot.userAgent,
      resolvedUserAgent: snapshot.resolvedUserAgent,
    );
    if (!ref.mounted) return;
    final nodes = resolved.parsed.nodes;
    if (nodes.isEmpty) {
      throw const SubscriptionException(
        'Refresh returned no proxies.',
        l10nKey: 'noValidProxies',
      );
    }
    await _serialized(() async {
      // The download may have taken seconds. Merge into the latest profile,
      // not the snapshot from before the request, so live node selection,
      // country overrides, and ping metadata cannot be overwritten.
      final currentProfile = _find(id);
      if (currentProfile == null || !currentProfile.isSubscription) return;
      _rejectActiveMutationDuringTransition(currentProfile.id);
      await _replaceConfigAndRestartIfActive(
        _mergeSubscriptionRefresh(currentProfile, resolved),
      );
    });
  }

  Future<void> setActive(String id) => _serialized(() async {
    final current = _current;
    if (current.activeId == id || !current.profiles.any((p) => p.id == id)) {
      return;
    }
    _rejectEngineTransition();
    final isConnected =
        ref.read(engineStateProvider).connection ==
        EngineConnectionState.connected;
    await _persist(current.copyWith(activeId: id));
    if (isConnected) {
      // Do not disconnect first: that briefly exposes the physical network on
      // devices without Android lockdown. Native restartWithConfig retains
      // the existing TUN keeper as a black hole until the new profile is live.
      try {
        final rollback = await RuntimeRollbackSnapshot.profiles(current);
        if (!ref.mounted) {
          throw StateError('Profiles provider was disposed.');
        }
        await ref
            .read(engineStateProvider.notifier)
            .restartWithCurrentConfiguration(rollback: rollback);
      } catch (error, stackTrace) {
        await _rollbackAfterFailedReplacement(current);
        Error.throwWithStackTrace(error, stackTrace);
      }
    }
  });

  /// Selects a server, or Nozelt's auto server with [Profile.nozeltAutoId].
  Future<void> setSelectedNode(String profileId, String nodeName) =>
      _serialized(() async {
        final profile = _find(profileId);
        if (profile == null) return;
        final Profile next;
        if (nodeName == Profile.nozeltAutoId) {
          if (!profile.supportsNozeltAuto) return;
          // Start from the server in use; the auto server then measures all
          // servers and moves to a faster one if there is one.
          next = profile.copyWith(
            selectedNodeName: Profile.nozeltAutoId,
            autoPickName: profile.effectiveSelectedNodeName,
          );
        } else {
          if (!profile.nodes.any((node) => node.name == nodeName)) return;
          next = profile.copyWith(selectedNodeName: nodeName);
        }
        await _applySelection(profile, next);
      });

  /// Moves the Nozelt auto server to [nodeName] (its fastest server).
  Future<void> setAutoPick(String profileId, String nodeName) => _serialized(
    () async {
      final profile = _find(profileId);
      if (profile == null || !profile.autoSelected) return;
      if (!profile.nodes.any((node) => node.name == nodeName)) return;
      if (profile.autoPick?.name == nodeName) return;
      await _applySelection(profile, profile.copyWith(autoPickName: nodeName));
    },
  );

  Future<void> _applySelection(Profile profile, Profile next) async {
    _rejectActiveMutationDuringTransition(profile.id);
    final target = next.effectiveSelectedNodeName;
    final isLive =
        _current.activeId == profile.id &&
        ref.read(engineStateProvider).connection ==
            EngineConnectionState.connected &&
        target != null &&
        target != profile.effectiveSelectedNodeName;
    if (isLive) {
      if (profile.effectiveCore == VpnCore.mihomo) {
        await ref.read(nozeltEngineProvider).selectProxy(target);
      } else {
        await _replaceConfigAndRestartIfActive(next);
        return;
      }
      if (!ref.mounted) return;
    }
    try {
      await _replace(next);
    } catch (_) {
      if (isLive && profile.effectiveSelectedNodeName != null) {
        try {
          await ref
              .read(nozeltEngineProvider)
              .selectProxy(profile.effectiveSelectedNodeName!);
        } catch (_) {
          // If even the lightweight selector rollback failed, rebuild the
          // encrypted runtime from the still-current old profile. The
          // notifier retains the original persistence error for the UI.
          try {
            await ref
                .read(engineStateProvider.notifier)
                .restartWithCurrentConfiguration();
          } catch (_) {
            // EngineNotifier already exposes the fail-closed error state.
            // Preserve the original encrypted-store failure for this
            // operation's caller instead of replacing it with recovery.
          }
        }
      }
      rethrow;
    }
  }

  Future<void> setNodeCountryOverride(
    String profileId,
    String nodeName,
    String? countryCode,
  ) => _serialized(
    () => _updateNodes(
      profileId,
      {nodeName},
      (node) => node.copyWith(
        countryCodeOverride: countryCode,
        clearCountryCodeOverride: countryCode == null,
      ),
    ),
  );

  /// Replaces every editable raw parameter of one proxy in a single durable
  /// transaction. A live active profile uses the existing fail-closed restart
  /// path, so invalid native configuration rolls both persistence and runtime
  /// back to the previous node.
  Future<void> updateNodeDetails(
    String profileId,
    String originalNodeName,
    Map<String, dynamic> raw,
    String? countryCode,
  ) => _serialized(() async {
    final profile = _find(profileId);
    if (profile == null) return;
    _rejectActiveMutationDuringTransition(profileId);

    final index = profile.nodes.indexWhere(
      (node) => node.name == originalNodeName,
    );
    if (index < 0) return;
    final previousNode = profile.nodes[index];
    final nextRaw = Map<String, dynamic>.of(raw);
    final name = (nextRaw['name'] ?? '').toString().trim();
    nextRaw['name'] = name;
    var replacementNode = ProxyNode.fromRaw(
      Map<String, dynamic>.unmodifiable(nextRaw),
    );
    if (!replacementNode.isUsableOutbound ||
        ProxyNode.normalizeNames([replacementNode]).single.name != name ||
        profile.nodes.any(
          (node) =>
              node.name != originalNodeName &&
              node.name.toLowerCase() == name.toLowerCase(),
        )) {
      throw const FormatException('invalid-proxy-parameters');
    }
    replacementNode = ProxyNode(
      name: replacementNode.name,
      type: replacementNode.type,
      server: replacementNode.server,
      port: replacementNode.port,
      raw: replacementNode.raw,
      detectedCountryCode: previousNode.detectedCountryCode,
      countryCodeOverride: countryCode,
      lastDelayMs: previousNode.lastDelayMs,
      lastDelayAt: previousNode.lastDelayAt,
    );

    final nodes = [...profile.nodes]..[index] = replacementNode;
    Set<String> renamed(Set<String> marks) => marks.contains(originalNodeName)
        ? {...marks.where((name) => name != originalNodeName), name}
        : marks;
    final selectedName = profile.effectiveSelectedNodeName == originalNodeName
        ? replacementNode.name
        : profile.effectiveSelectedNodeName;
    await _replaceConfigAndRestartIfActive(
      profile.copyWith(
        nodes: nodes,
        selectedNodeName: selectedName,
        pinnedNodeNames: renamed(profile.pinnedNodeNames),
        deletedNodeNames: renamed(profile.deletedNodeNames),
        topologyRevision: profile.topologyRevision + 1,
        detectedCore: detectProfileCore(nodes.map((node) => node.raw)),
      ),
    );
  });

  Future<void> setDetectedCountries(
    String profileId,
    Map<String, String> countryCodes,
  ) => _serialized(
    () => _updateNodes(
      profileId,
      countryCodes.keys.toSet(),
      (node) => node.copyWith(detectedCountryCode: countryCodes[node.name]),
    ),
  );

  Future<void> rename(String id, String name) => _serialized(() async {
    final p = _find(id);
    if (p == null) return;
    await _replace(
      p.copyWith(name: normalizeProfileName(name), nameCustomized: true),
    );
  });

  Future<void> updateDetails(
    String id, {
    required String name,
    required int autoUpdateMinutes,
    ProfileCoreMode? coreMode,
    VpnCore? manualCore,
    bool? nozeltAuto,
  }) async {
    final snapshot = _find(id);
    if (snapshot == null) return;
    final replacement = snapshot.copyWith(
      name: normalizeProfileName(name),
      nameCustomized: true,
      nozeltAuto: nozeltAuto,
      autoUpdateMinutes: snapshot.isSubscription
          ? autoUpdateMinutes.clamp(30, 24 * 60 * 30).toInt()
          : snapshot.autoUpdateMinutes,
      coreMode: coreMode,
      manualCore: manualCore,
    );
    final selectionChanged =
        replacement.coreMode != snapshot.coreMode ||
        replacement.manualCore != snapshot.manualCore;
    if (snapshot.isSubscription && selectionChanged) {
      final resolved = await _downloadAndDetect(
        url: snapshot.source,
        coreMode: replacement.coreMode,
        manualCore: replacement.manualCore,
        explicitUserAgent: snapshot.userAgent,
        // Returning to automatic mode deliberately renegotiates instead of
        // inheriting the representation chosen by the previous manual core.
        resolvedUserAgent: replacement.coreMode == ProfileCoreMode.automatic
            ? null
            : snapshot.resolvedUserAgent,
        forceCoreRepresentation: replacement.coreMode == ProfileCoreMode.manual,
      );
      await _serialized(() async {
        final latest = _find(id);
        if (latest == null || !latest.isSubscription) return;
        _rejectActiveMutationDuringTransition(id);
        await _replaceConfigAndRestartIfActive(
          _mergeSubscriptionRefresh(
            latest.copyWith(
              nozeltAuto: nozeltAuto,
              selectedNodeName: nozeltAuto == false && latest.autoSelected
                  ? latest.effectiveSelectedNodeName
                  : null,
            ),
            resolved,
            explicitName: name,
            autoUpdateMinutes: replacement.autoUpdateMinutes,
            coreMode: replacement.coreMode,
            manualCore: replacement.manualCore,
          ),
        );
      });
      return;
    }
    await _serialized(() async {
      final latest = _find(id);
      if (latest == null) return;
      final localReplacement = latest.copyWith(
        name: normalizeProfileName(name),
        nameCustomized: true,
        autoUpdateMinutes: latest.isSubscription
            ? autoUpdateMinutes.clamp(30, 24 * 60 * 30).toInt()
            : latest.autoUpdateMinutes,
        coreMode: coreMode,
        manualCore: manualCore,
        nozeltAuto: nozeltAuto,
        // Turning the auto server off keeps the server it was using.
        selectedNodeName: nozeltAuto == false && latest.autoSelected
            ? latest.effectiveSelectedNodeName
            : null,
      );
      if (localReplacement.effectiveCore != latest.effectiveCore) {
        await _replaceConfigAndRestartIfActive(localReplacement);
      } else {
        await _replace(localReplacement);
      }
    });
  }

  Future<void> setCoreSelection(
    String id, {
    required ProfileCoreMode mode,
    required VpnCore manualCore,
  }) async {
    final snapshot = _find(id);
    if (snapshot == null) return;
    final replacement = snapshot.copyWith(
      coreMode: mode,
      manualCore: manualCore,
    );
    if (replacement.effectiveCore == snapshot.effectiveCore &&
        replacement.coreMode == snapshot.coreMode &&
        replacement.manualCore == snapshot.manualCore) {
      return;
    }
    if (snapshot.isSubscription) {
      final resolved = await _downloadAndDetect(
        url: snapshot.source,
        coreMode: mode,
        manualCore: manualCore,
        explicitUserAgent: snapshot.userAgent,
        resolvedUserAgent: mode == ProfileCoreMode.automatic
            ? null
            : snapshot.resolvedUserAgent,
        forceCoreRepresentation: mode == ProfileCoreMode.manual,
      );
      await _serialized(() async {
        final latest = _find(id);
        if (latest == null || !latest.isSubscription) return;
        _rejectActiveMutationDuringTransition(id);
        await _replaceConfigAndRestartIfActive(
          _mergeSubscriptionRefresh(
            latest,
            resolved,
            coreMode: mode,
            manualCore: manualCore,
          ),
        );
      });
      return;
    }
    await _serialized(() async {
      final latest = _find(id);
      if (latest == null) return;
      await _replaceConfigAndRestartIfActive(
        latest.copyWith(coreMode: mode, manualCore: manualCore),
      );
    });
  }

  Future<void> setAutoUpdate(String id, int minutes) => _serialized(() async {
    final p = _find(id);
    if (p == null) return;
    await _replace(p.copyWith(autoUpdateMinutes: minutes));
  });

  Future<void> togglePinned(String id) => _serialized(() async {
    final profile = _find(id);
    if (profile == null) return;
    await _replace(profile.copyWith(pinned: !profile.pinned));
  });

  /// Pins a server to the top of its list, or unpins it.
  Future<void> toggleNodePinned(String profileId, String nodeName) =>
      _serialized(() async {
        final profile = _find(profileId);
        if (profile == null ||
            !profile.nodes.any((node) => node.name == nodeName)) {
          return;
        }
        final pinned = profile.isNodePinned(nodeName);
        await _replace(
          profile.copyWith(
            pinnedNodeNames: pinned
                ? profile.pinnedNodeNames.difference({nodeName})
                : {...profile.pinnedNodeNames, nodeName},
          ),
        );
      });

  /// Moves a server to the "Deleted" section, or restores it. The server
  /// stays selectable; only automatic selection changes. When the live
  /// config has automatic groups that change, the engine rebuilds it.
  Future<void> setNodeDeleted(
    String profileId,
    String nodeName,
    bool deleted,
  ) => _serialized(() async {
    final profile = _find(profileId);
    if (profile == null ||
        !profile.nodes.any((node) => node.name == nodeName) ||
        profile.isNodeDeleted(nodeName) == deleted) {
      return;
    }
    final next = profile.copyWith(
      deletedNodeNames: deleted
          ? {...profile.deletedNodeNames, nodeName}
          : profile.deletedNodeNames.difference({nodeName}),
    );
    final groupsChanged =
        next.autoExclusion != profile.autoExclusion &&
        (usesAutomaticGroups(profile) || usesAutomaticGroups(next));
    if (groupsChanged) {
      _rejectActiveMutationDuringTransition(profileId);
      await _replaceConfigAndRestartIfActive(next);
    } else {
      // The auto server may have to leave a server that was just deleted.
      await _applySelection(profile, next);
    }
  });

  Future<void> delete(String id) => _serialized(() async {
    var cur = _current;
    _rejectActiveMutationDuringTransition(id);
    final deletingLiveProfile =
        cur.activeId == id &&
        ref.read(engineStateProvider).connection ==
            EngineConnectionState.connected;
    if (deletingLiveProfile) {
      await _disconnectForActiveProfileMutation();
      cur = _current;
    }
    final remaining = cur.profiles.where((p) => p.id != id).toList();
    final clearActive = cur.activeId == id;
    try {
      await _persist(
        ProfilesState(
          profiles: remaining,
          activeId: clearActive ? null : cur.activeId,
        ),
      );
    } catch (_) {
      if (deletingLiveProfile) {
        // The store still contains the original active profile. Bring it back
        // rather than turning a failed delete into an unrelated outage.
        await ref.read(engineStateProvider.notifier).connect();
      }
      rethrow;
    }
  });

  /// A refreshed active subscription changes the actual proxy definitions.
  /// Restart the engine around that mutation so the UI, encrypted store, and
  /// live mihomo config cannot disagree about credentials or available nodes.
  Future<void> _replaceConfigAndRestartIfActive(Profile replacement) async {
    final isConnected =
        _current.activeId == replacement.id &&
        ref.read(engineStateProvider).connection ==
            EngineConnectionState.connected;
    final previous = _current;
    await _replace(replacement);
    if (isConnected) {
      // Subscription refresh can run automatically. A normal disconnect here
      // would create an unrequested clear-underlay window. Reuse the same
      // fail-closed TUN replacement as stack/MTU/app-routing changes instead.
      try {
        final rollback = await RuntimeRollbackSnapshot.profiles(previous);
        if (!ref.mounted) {
          throw StateError('Profiles provider was disposed.');
        }
        await ref
            .read(engineStateProvider.notifier)
            .restartWithCurrentConfiguration(rollback: rollback);
      } catch (error, stackTrace) {
        await _rollbackAfterFailedReplacement(previous);
        Error.throwWithStackTrace(error, stackTrace);
      }
    }
  }

  /// Restores the exact profile snapshot that was live before a failed full
  /// replacement. If the native core already entered its error/keeper state,
  /// rebuild that old snapshot as well so encrypted storage, UI, and runtime
  /// converge instead of merely looking rolled back.
  Future<void> _rollbackAfterFailedReplacement(ProfilesState previous) async {
    var rollbackPersisted = false;
    try {
      await _persist(previous);
      rollbackPersisted = true;
    } catch (_) {
      // The original replacement failure remains authoritative. If secure
      // storage is unavailable, retain the newer in-memory/durable snapshot
      // and leave the engine fail closed rather than guessing which won.
    }
    if (!rollbackPersisted ||
        ref.read(engineStateProvider).connection !=
            EngineConnectionState.error) {
      return;
    }
    try {
      await ref
          .read(engineStateProvider.notifier)
          .restartWithCurrentConfiguration(allowErrorRecovery: true);
    } catch (_) {
      // EngineNotifier publishes rollback-recovery failure through its state;
      // the initiating operation still throws its original apply failure.
    }
  }

  /// Refreshes every subscription whose interval has elapsed. Startup,
  /// foreground-resume, and maintenance-timer calls share one in-flight
  /// operation; failures per profile are best-effort and offline-safe.
  Future<void> refreshStale() {
    final running = _staleRefreshOperation;
    if (running != null) return running;

    late final Future<void> operation;
    operation = _refreshStaleOnce().whenComplete(() {
      if (identical(_staleRefreshOperation, operation)) {
        _staleRefreshOperation = null;
      }
    });
    _staleRefreshOperation = operation;
    return operation;
  }

  Future<void> _refreshStaleOnce() async {
    // Work from a snapshot. Each refresh merges into the latest persisted
    // profile before writing, so concurrent ping/country metadata is retained.
    for (final p in [..._current.profiles]) {
      if (!ref.mounted) return;
      if (p.isStale) {
        try {
          await refresh(p.id);
          if (!ref.mounted) return;
        } catch (_) {
          if (kDebugMode) debugPrint('stale subscription refresh failed');
        }
      }
    }
  }

  Profile? _find(String id) {
    for (final p in _current.profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<void> _replace(Profile updated) async {
    final cur = _current;
    final list = cur.profiles
        .map((p) => p.id == updated.id ? updated : p)
        .toList();
    await _persist(cur.copyWith(profiles: list));
  }

  Future<void> _updateNodes(
    String profileId,
    Set<String> names,
    ProxyNode Function(ProxyNode node) update,
  ) async {
    final profile = _find(profileId);
    if (profile == null) return;
    final nodes = profile.nodes
        .map((node) => names.contains(node.name) ? update(node) : node)
        .toList(growable: false);
    final updated = profile.copyWith(nodes: nodes);
    await _replace(updated);
  }

  String? _notificationIdentity(ProfilesState value) {
    final profile = value.active;
    final node = profile?.selectedNode;
    if (profile == null || node == null) return null;
    return '${profile.id}\u0000${node.name}\u0000${node.server}\u0000${node.port}';
  }

  void _syncActiveNotification(ProfilesState value) {
    final profile = value.active;
    final node = profile?.selectedNode;
    final identity = _notificationIdentity(value);
    final changed = identity != _notificationNodeIdentity;
    _notificationNodeIdentity = identity;
    if (profile == null || node == null) return;
    unawaited(
      ref
          .read(nozeltEngineProvider)
          .updateVpnNotification(
            flag: node.flagEmoji,
            serverName: node.displayName,
            updatePing: changed,
          )
          .catchError((_) => false),
    );
  }

  void _rejectActiveMutationDuringTransition(String profileId) {
    if (_current.activeId == profileId) _rejectEngineTransition();
  }

  void _rejectEngineTransition() {
    final connection = ref.read(engineStateProvider).connection;
    if (connection == EngineConnectionState.connecting ||
        connection == EngineConnectionState.disconnecting) {
      throw const ProfileMutationBusyException();
    }
  }

  Future<void> _disconnectForActiveProfileMutation() async {
    if (await ref.read(nozeltEngineProvider).isAlwaysOnVpn()) {
      throw const ProfileMutationRequiresVpnStopException();
    }
    if (!ref.mounted) {
      throw StateError(
        'Profiles provider was disposed during VPN policy read.',
      );
    }
    await ref.read(engineStateProvider.notifier).disconnect();
    if (!ref.mounted) {
      throw StateError('Profiles provider was disposed during disconnect.');
    }
    if (ref.read(engineStateProvider).connection !=
        EngineConnectionState.disconnected) {
      throw const ProfileMutationBusyException();
    }
  }

  /// AsyncNotifier methods may be triggered by UI taps, background refresh,
  /// GeoIP detection, and ping completion at the same time. Serialize only
  /// the state-changing tail of those operations so every mutation reads the
  /// latest encrypted state and atomic saves cannot complete out of order.
  Future<T> _serialized<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _mutationTail = _mutationTail.then((_) async {
      try {
        if (!ref.mounted) {
          throw StateError('Profiles provider was disposed during mutation.');
        }
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  static String _subscriptionHost(String url) {
    final uri = Uri.tryParse(url);
    return uri == null || uri.host.isEmpty ? 'Nozelt' : uri.host;
  }
}

/// True when the config generated for [profile] contains automatic groups
/// whose members depend on the deleted servers.
@visibleForTesting
bool usesAutomaticGroups(Profile profile) {
  const automatic = {'url-test', 'fallback', 'load-balance'};
  if (profile.effectiveCore == VpnCore.mihomo) {
    if (profile.nodes.any((node) => node.isAutomaticGroup)) return true;
    final groups = profile.providerRouting['proxy-groups'];
    return groups is List &&
        groups.whereType<Map>().any(
          (group) => automatic.contains(group['type']?.toString()),
        );
  }
  final native = profile.selectedNode?.raw['nozelt-native-config'];
  if (native is! Map) return false;
  final routing = native['routing'];
  if (routing is Map && routing['balancers'] is List) {
    return (routing['balancers'] as List).isNotEmpty;
  }
  final outbounds = native['outbounds'];
  return outbounds is List &&
      outbounds.whereType<Map>().any((item) => item['type'] == 'urltest');
}

final profilesProvider = AsyncNotifierProvider<ProfilesNotifier, ProfilesState>(
  ProfilesNotifier.new,
);
