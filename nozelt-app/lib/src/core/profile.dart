import 'dart:convert';

import 'proxy_marks.dart';
import 'proxy_node.dart';
import 'vpn_core.dart';

const int maxProfileNameRunes = 96;
const int maxSubscriptionDescriptionRunes = 4096;

String normalizeProfileName(String value) {
  var normalized = _repairUtf8DecodedAsWindows1251(value)
      .replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (normalized.runes.length > maxProfileNameRunes) {
    normalized = String.fromCharCodes(
      normalized.runes.take(maxProfileNameRunes),
    ).trimRight();
  }
  return normalized.isEmpty ? 'Nozelt' : normalized;
}

String _repairUtf8DecodedAsWindows1251(String value) {
  final bytes = <int>[];
  for (final rune in value.runes) {
    final byte = _windows1251Byte(rune);
    if (byte == null) return value;
    bytes.add(byte);
  }
  try {
    final repaired = utf8.decode(bytes, allowMalformed: false);
    return repaired == value || repaired.contains('\uFFFD') ? value : repaired;
  } catch (_) {
    return value;
  }
}

int? _windows1251Byte(int rune) {
  if (rune <= 0x7f || (rune >= 0x80 && rune <= 0x9f)) return rune;
  if (rune >= 0x0410 && rune <= 0x042f) return 0xc0 + rune - 0x0410;
  if (rune >= 0x0430 && rune <= 0x044f) return 0xe0 + rune - 0x0430;
  const special = <int, int>{
    0x0402: 0x80,
    0x0403: 0x81,
    0x201a: 0x82,
    0x0453: 0x83,
    0x201e: 0x84,
    0x2026: 0x85,
    0x2020: 0x86,
    0x2021: 0x87,
    0x20ac: 0x88,
    0x2030: 0x89,
    0x0409: 0x8a,
    0x2039: 0x8b,
    0x040a: 0x8c,
    0x040c: 0x8d,
    0x040b: 0x8e,
    0x040f: 0x8f,
    0x0452: 0x90,
    0x2018: 0x91,
    0x2019: 0x92,
    0x201c: 0x93,
    0x201d: 0x94,
    0x2022: 0x95,
    0x2013: 0x96,
    0x2014: 0x97,
    0x02dc: 0x98,
    0x2122: 0x99,
    0x0459: 0x9a,
    0x203a: 0x9b,
    0x045a: 0x9c,
    0x045c: 0x9d,
    0x045b: 0x9e,
    0x045f: 0x9f,
    0x00a0: 0xa0,
    0x040e: 0xa1,
    0x045e: 0xa2,
    0x0408: 0xa3,
    0x00a4: 0xa4,
    0x0490: 0xa5,
    0x00a6: 0xa6,
    0x00a7: 0xa7,
    0x0401: 0xa8,
    0x00a9: 0xa9,
    0x0404: 0xaa,
    0x00ab: 0xab,
    0x00ac: 0xac,
    0x00ad: 0xad,
    0x00ae: 0xae,
    0x0407: 0xaf,
    0x00b0: 0xb0,
    0x00b1: 0xb1,
    0x0406: 0xb2,
    0x0456: 0xb3,
    0x0491: 0xb4,
    0x00b5: 0xb5,
    0x00b6: 0xb6,
    0x00b7: 0xb7,
    0x0451: 0xb8,
    0x2116: 0xb9,
    0x0454: 0xba,
    0x00bb: 0xbb,
    0x0458: 0xbc,
    0x0405: 0xbd,
    0x0455: 0xbe,
    0x0457: 0xbf,
  };
  return special[rune];
}

class SubscriptionMetadata {
  const SubscriptionMetadata({
    this.title,
    this.uploadBytes,
    this.downloadBytes,
    this.totalBytes,
    this.expiresAt,
    this.description,
    this.webPageUrl,
  });

  final String? title;
  final int? uploadBytes;
  final int? downloadBytes;
  final int? totalBytes;
  final DateTime? expiresAt;
  final String? description;
  final String? webPageUrl;

  int get usedBytes => (uploadBytes ?? 0) + (downloadBytes ?? 0);

  bool get hasTrafficUsage => uploadBytes != null || downloadBytes != null;

  bool get hasTrafficLimit => totalBytes != null && totalBytes! > 0;

  String? get telegramUrl {
    final value = webPageUrl;
    if (value == null) return null;
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.isScheme('https')) return null;
    final host = uri.host.toLowerCase();
    return host == 't.me' ||
            host == 'telegram.me' ||
            host.endsWith('.t.me') ||
            host.endsWith('.telegram.me')
        ? uri.toString()
        : null;
  }

  bool get isEmpty =>
      title == null &&
      uploadBytes == null &&
      downloadBytes == null &&
      totalBytes == null &&
      expiresAt == null &&
      description == null &&
      webPageUrl == null;

  SubscriptionMetadata merge(SubscriptionMetadata other) =>
      SubscriptionMetadata(
        title: other.title ?? title,
        uploadBytes: other.uploadBytes ?? uploadBytes,
        downloadBytes: other.downloadBytes ?? downloadBytes,
        totalBytes: other.totalBytes ?? totalBytes,
        expiresAt: other.expiresAt ?? expiresAt,
        description: other.description ?? description,
        webPageUrl: other.webPageUrl ?? webPageUrl,
      );

  Map<String, dynamic> toJson() => {
    'title': title,
    'uploadBytes': uploadBytes,
    'downloadBytes': downloadBytes,
    'totalBytes': totalBytes,
    'expiresAt': expiresAt?.toIso8601String(),
    'description': description,
    'webPageUrl': webPageUrl,
  };

  factory SubscriptionMetadata.fromJson(Map<String, dynamic> json) =>
      SubscriptionMetadata(
        title: _boundedText(json['title'], maxProfileNameRunes),
        uploadBytes: _nonNegativeInt(json['uploadBytes']),
        downloadBytes: _nonNegativeInt(json['downloadBytes']),
        totalBytes: _positiveInt(json['totalBytes']),
        expiresAt: DateTime.tryParse(json['expiresAt']?.toString() ?? ''),
        description: _boundedText(
          json['description'],
          maxSubscriptionDescriptionRunes,
        ),
        webPageUrl: _safeMetadataUrl(json['webPageUrl']),
      );
}

String? _boundedText(Object? value, int maxRunes) {
  final text = value?.toString().trim();
  if (text == null || text.isEmpty) return null;
  return String.fromCharCodes(text.runes.take(maxRunes));
}

int? _nonNegativeInt(Object? value) {
  final parsed = value is num
      ? value.toInt()
      : int.tryParse(value?.toString() ?? '');
  return parsed != null && parsed >= 0 ? parsed : null;
}

int? _positiveInt(Object? value) {
  final parsed = _nonNegativeInt(value);
  return parsed != null && parsed > 0 ? parsed : null;
}

String? _safeMetadataUrl(Object? value) {
  final text = _boundedText(value, 8192);
  final uri = text == null ? null : Uri.tryParse(text);
  return uri != null && uri.isScheme('https') && uri.host.isNotEmpty
      ? uri.toString()
      : null;
}

/// Where a profile's proxies come from.
enum ProfileType {
  /// Nodes pasted directly as share links.
  manual,

  /// A subscription URL that is downloaded and re-parsed on refresh.
  subscription,

  /// An imported Clash/mihomo YAML document.
  file;

  static ProfileType fromName(String? v) => ProfileType.values.firstWhere(
    (t) => t.name == v,
    orElse: () => ProfileType.manual,
  );
}

/// A named source of proxy nodes. Several profiles can coexist; exactly one is
/// active at a time (its nodes feed the generated config). The model is built
/// to extend to multi-active/merge later without a schema change.
class Profile {
  const Profile({
    required this.id,
    required this.name,
    required this.type,
    required this.source,
    required this.nodes,
    this.providerRouting = const {},
    this.updatedAt,
    int? autoUpdateMinutes,
    int autoUpdateHours = 0,
    this.userAgent,
    this.resolvedUserAgent,
    this.subscriptionMetadata,
    this.nameCustomized = true,
    this.pinned = false,
    this.selectedNodeName,
    this.topologyRevision = 0,
    this.coreMode = ProfileCoreMode.automatic,
    this.manualCore = VpnCore.mihomo,
    this.detectedCore = VpnCore.mihomo,
    this.nozeltAuto = false,
    this.autoPickName,
    this.pinnedNodeNames = const {},
    this.deletedNodeNames = const {},
  }) : autoUpdateMinutes = autoUpdateMinutes ?? autoUpdateHours * 60;

  /// Selection id of Nozelt's own automatic server. It is not a node: while
  /// it is selected, [autoPickName] names the real server in use, so every
  /// core simply connects to that server.
  static const nozeltAutoId = 'nozelt:auto';
  static const nozeltAutoName = 'Авто (Nozelt)';

  /// User choice: show the Nozelt auto server for this profile.
  final bool nozeltAuto;

  /// Real server currently chosen by the Nozelt auto server.
  final String? autoPickName;

  /// Servers the user pinned: shown first in their list. Refresh keeps them.
  final Set<String> pinnedNodeNames;

  /// Servers the user deleted: shown in the collapsed "Deleted" section at
  /// the bottom of the profile. They still come from the subscription (a
  /// refresh updates their parameters), can be selected by hand, but
  /// automatic selection skips them.
  final Set<String> deletedNodeNames;

  bool isNodePinned(String name) => pinnedNodeNames.contains(name);

  bool isNodeDeleted(String name) => deletedNodeNames.contains(name);

  /// Servers outside the "Deleted" section, pinned first, in list order.
  List<ProxyNode> get listedNodes =>
      _ordered(nodes.where((node) => !deletedNodeNames.contains(node.name)));

  /// The "Deleted" section, pinned first, in list order.
  List<ProxyNode> get deletedNodes => deletedNodeNames.isEmpty
      ? const []
      : _ordered(nodes.where((node) => deletedNodeNames.contains(node.name)));

  List<ProxyNode> _ordered(Iterable<ProxyNode> source) {
    final list = source.toList(growable: false);
    if (pinnedNodeNames.isEmpty) return list;
    return [
      ...list.where((node) => pinnedNodeNames.contains(node.name)),
      ...list.where((node) => !pinnedNodeNames.contains(node.name)),
    ];
  }

  /// Servers the Nozelt auto server may use. With every server deleted it
  /// falls back to the full list instead of having nothing to pick.
  List<ProxyNode> get autoCandidates {
    if (deletedNodeNames.isEmpty) return nodes;
    final kept = nodes
        .where((node) => !deletedNodeNames.contains(node.name))
        .toList(growable: false);
    return kept.isEmpty ? nodes : kept;
  }

  /// What the config builders leave out of automatic groups.
  AutoExclusion get autoExclusion =>
      AutoExclusion.forNodes(nodes, deletedNodeNames);

  /// Any profile with at least two servers can use the auto server.
  bool get supportsNozeltAuto => nozeltAuto && nodes.length >= 2;

  /// True while the user has the Nozelt auto server selected.
  bool get autoSelected =>
      supportsNozeltAuto && selectedNodeName == nozeltAutoId;

  /// The real server the auto server currently uses.
  ProxyNode? get autoPick {
    if (!supportsNozeltAuto) return null;
    final candidates = autoCandidates;
    for (final node in candidates) {
      if (node.name == autoPickName) return node;
    }
    return candidates.first;
  }

  final String id;
  final String name;
  final ProfileType type;

  /// For [ProfileType.subscription]: the URL (a secret — never logged, masked
  /// in UI). Manual links and imported YAML are cleared after parsing because
  /// [nodes] already carry the required fields without a duplicate secret.
  final String source;

  final List<ProxyNode> nodes;
  final Map<String, dynamic> providerRouting;

  /// Last successful parse/refresh time.
  final DateTime? updatedAt;

  /// Auto-refresh interval in hours; `0` disables it. Only meaningful for
  /// subscriptions.
  /// Per-profile subscription refresh interval. Minutes are used so the
  /// standard 30-minute option does not need a lossy fractional-hour value.
  final int autoUpdateMinutes;

  /// Optional User-Agent override for subscription downloads (some panels gate
  /// the response format on it). Null → the client default.
  final String? userAgent;

  /// User-Agent selected by automatic multi-core content negotiation.
  ///
  /// [userAgent] is the user's explicit override and always wins. This value
  /// records which provider representation successfully matched the selected
  /// core, so later refreshes do not have to download every representation.
  final String? resolvedUserAgent;

  final SubscriptionMetadata? subscriptionMetadata;

  /// False when the title was inferred from subscription metadata and may be
  /// updated by a later refresh. Explicit user renames set this to true.
  final bool nameCustomized;

  /// Pinned profiles are displayed before the rest on the proxy page.
  ///
  /// This is deliberately independent from [ProfilesState.activeId]: pinning
  /// only controls presentation order, while the active profile supplies the
  /// live VPN configuration.
  final bool pinned;

  /// Explicit node selected for this profile. Legacy profiles without a value
  /// automatically migrate to their first node.
  final String? selectedNodeName;

  /// Changes only when the technical node set changes, not when latency,
  /// country, or selection metadata is saved. Consumers can observe topology
  /// in O(1) instead of hashing thousands of nodes after every ping result.
  final int topologyRevision;

  /// Automatic mode follows the format detected during import/refresh.
  /// Manual mode pins this profile to [manualCore].
  final ProfileCoreMode coreMode;
  final VpnCore manualCore;
  final VpnCore detectedCore;

  VpnCore get effectiveCore =>
      coreMode == ProfileCoreMode.manual ? manualCore : detectedCore;

  ProxyNode? get selectedNode {
    final selected = effectiveSelectedNodeName;
    if (selected == null) return null;
    for (final node in nodes) {
      if (node.name == selected) return node;
    }
    return null;
  }

  String? get effectiveSelectedNodeName {
    // With the auto server selected, the engine connects to its pick.
    if (autoSelected) return autoPick?.name;
    final selected = selectedNodeName;
    if (selected != null && nodes.any((node) => node.name == selected)) {
      return selected;
    }
    return nodes.isEmpty ? null : nodes.first.name;
  }

  bool get isSubscription => type == ProfileType.subscription;

  /// Whether an auto-update is due (subscription, interval set, and stale).
  bool get isStale {
    if (!isSubscription || autoUpdateMinutes <= 0) return false;
    final last = updatedAt;
    if (last == null) return true;
    return DateTime.now().difference(last) >=
        Duration(minutes: autoUpdateMinutes);
  }

  Profile copyWith({
    String? name,
    String? source,
    List<ProxyNode>? nodes,
    Map<String, dynamic>? providerRouting,
    DateTime? updatedAt,
    int? autoUpdateMinutes,
    String? userAgent,
    String? resolvedUserAgent,
    bool clearResolvedUserAgent = false,
    SubscriptionMetadata? subscriptionMetadata,
    bool clearSubscriptionMetadata = false,
    bool? nameCustomized,
    bool? pinned,
    String? selectedNodeName,
    bool clearSelectedNode = false,
    int? topologyRevision,
    ProfileCoreMode? coreMode,
    VpnCore? manualCore,
    VpnCore? detectedCore,
    bool? nozeltAuto,
    String? autoPickName,
    Set<String>? pinnedNodeNames,
    Set<String>? deletedNodeNames,
  }) {
    final next = Profile(
      id: id,
      name: name ?? this.name,
      type: type,
      source: source ?? this.source,
      nodes: nodes ?? this.nodes,
      providerRouting: providerRouting ?? this.providerRouting,
      updatedAt: updatedAt ?? this.updatedAt,
      autoUpdateMinutes: autoUpdateMinutes ?? this.autoUpdateMinutes,
      userAgent: userAgent ?? this.userAgent,
      resolvedUserAgent: clearResolvedUserAgent
          ? null
          : (resolvedUserAgent ?? this.resolvedUserAgent),
      subscriptionMetadata: clearSubscriptionMetadata
          ? null
          : (subscriptionMetadata ?? this.subscriptionMetadata),
      nameCustomized: nameCustomized ?? this.nameCustomized,
      pinned: pinned ?? this.pinned,
      selectedNodeName: clearSelectedNode
          ? null
          : (selectedNodeName ?? this.selectedNodeName),
      topologyRevision: topologyRevision ?? this.topologyRevision,
      coreMode: coreMode ?? this.coreMode,
      manualCore: manualCore ?? this.manualCore,
      detectedCore: detectedCore ?? this.detectedCore,
      nozeltAuto: nozeltAuto ?? this.nozeltAuto,
      autoPickName: autoPickName ?? this.autoPickName,
      pinnedNodeNames: pinnedNodeNames ?? this.pinnedNodeNames,
      deletedNodeNames: deletedNodeNames ?? this.deletedNodeNames,
    );
    return next;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type.name,
    'source': source,
    'nodes': nodes.map((n) => n.toJson()).toList(),
    'nozeltAuto': nozeltAuto,
    'providerRouting': providerRouting,
    'updatedAt': updatedAt?.toIso8601String(),
    'autoUpdateMinutes': autoUpdateMinutes,
    'userAgent': userAgent,
    'resolvedUserAgent': resolvedUserAgent,
    'subscriptionMetadata': subscriptionMetadata?.toJson(),
    'nameCustomized': nameCustomized,
    'pinned': pinned,
    // The auto server stays selected across restarts; its pick is separate.
    'selectedNodeName': autoSelected ? nozeltAutoId : effectiveSelectedNodeName,
    'autoPickName': autoPick?.name,
    'pinnedNodes': _existing(pinnedNodeNames),
    'deletedNodes': _existing(deletedNodeNames),
    'topologyRevision': topologyRevision,
    'coreMode': coreMode.name,
    'manualCore': manualCore.wireName,
    'detectedCore': detectedCore.wireName,
  };

  /// Marks of servers that are still in the profile, in list order.
  List<String> _existing(Set<String> marks) => marks.isEmpty
      ? const []
      : [
          for (final node in nodes)
            if (marks.contains(node.name)) node.name,
        ];

  factory Profile.fromJson(Map<String, dynamic> json) {
    final parsedNodes = ((json['nodes'] as List?) ?? const [])
        .take(maxProxyNodes)
        .map((e) => ProxyNode.fromJson((e as Map).cast<String, dynamic>()))
        .where((node) => node.isUsableOutbound)
        .toList();
    final storedSelection = json['selectedNodeName'] as String?;
    final selectedIndex = storedSelection == null
        ? -1
        : parsedNodes.indexWhere((node) => node.name == storedSelection);
    final nodes = ProxyNode.normalizeNames(parsedNodes);
    // Names are re-normalized on load; marks follow their server by index.
    final normalizedNames = <String, String>{
      for (var i = 0; i < nodes.length; i++) parsedNodes[i].name: nodes[i].name,
    };
    Set<String> marks(Object? value) => {
      if (value is List)
        for (final name in value)
          if (normalizedNames[name?.toString()] case final String mapped)
            mapped,
    };
    final type = ProfileType.fromName(json['type'] as String?);
    final source = json['source'] as String? ?? '';
    final name = normalizeProfileName(json['name']?.toString() ?? '');
    final sourceHost = Uri.tryParse(source)?.host;
    final legacyAutomaticName =
        type == ProfileType.subscription &&
        ((sourceHost != null &&
                sourceHost.isNotEmpty &&
                name.toLowerCase() == sourceHost.toLowerCase()) ||
            (name.contains('.') &&
                !name.contains(RegExp(r'\s')) &&
                Uri.tryParse('https://$name')?.host.toLowerCase() ==
                    name.toLowerCase()));
    return Profile(
      id: json['id'] as String,
      name: name,
      type: type,
      source: source,
      nodes: nodes,
      providerRouting:
          (json['providerRouting'] as Map?)?.cast<String, dynamic>() ??
          const {},
      updatedAt: (json['updatedAt'] as String?) != null
          ? DateTime.tryParse(json['updatedAt'] as String)
          : null,
      autoUpdateMinutes:
          (json['autoUpdateMinutes'] as num?)
              ?.toInt()
              .clamp(0, 24 * 60 * 30)
              .toInt() ??
          (((json['autoUpdateHours'] as num?)?.toInt() ?? 0) * 60)
              .clamp(0, 24 * 60 * 30)
              .toInt(),
      userAgent: json['userAgent'] as String?,
      resolvedUserAgent: json['resolvedUserAgent'] as String?,
      subscriptionMetadata: json['subscriptionMetadata'] is Map
          ? SubscriptionMetadata.fromJson(
              (json['subscriptionMetadata'] as Map).cast<String, dynamic>(),
            )
          : null,
      // A legacy title equal to the subscription host came from Nozelt's old
      // automatic fallback and may safely adopt the provider's real title.
      // Any other legacy title is treated as an explicit user choice.
      nameCustomized: json['nameCustomized'] as bool? ?? !legacyAutomaticName,
      pinned: json['pinned'] as bool? ?? false,
      selectedNodeName: selectedIndex >= 0
          ? nodes[selectedIndex].name
          // The Nozelt auto server is a selection, not a node.
          : storedSelection == nozeltAutoId && json['nozeltAuto'] == true
          ? storedSelection
          : (nodes.isEmpty ? null : nodes.first.name),
      topologyRevision: ((json['topologyRevision'] as num?)?.toInt() ?? 0)
          .clamp(0, 0x7fffffff),
      coreMode: ProfileCoreMode.fromName(json['coreMode']),
      manualCore: VpnCore.fromWireName(json['manualCore']),
      detectedCore: json.containsKey('detectedCore')
          ? VpnCore.fromWireName(json['detectedCore'])
          : detectProfileCore(nodes.map((node) => node.raw)),
      nozeltAuto: json['nozeltAuto'] as bool? ?? false,
      autoPickName: json['autoPickName'] as String?,
      pinnedNodeNames: marks(json['pinnedNodes']),
      deletedNodeNames: marks(json['deletedNodes']),
    );
  }
}

/// The full persisted profiles state: the list plus which one is active.
class ProfilesState {
  const ProfilesState({this.profiles = const [], this.activeId});

  final List<Profile> profiles;
  final String? activeId;

  Profile? get active {
    if (activeId == null) return null;
    for (final p in profiles) {
      if (p.id == activeId) return p;
    }
    return null;
  }

  /// Nodes of the active profile, or empty when there is no active profile.
  List<ProxyNode> get activeNodes => active?.nodes ?? const [];

  ProfilesState copyWith({
    List<Profile>? profiles,
    String? activeId,
    bool clearActive = false,
  }) {
    return ProfilesState(
      profiles: profiles ?? this.profiles,
      activeId: clearActive ? null : (activeId ?? this.activeId),
    );
  }

  Map<String, dynamic> toJson() => {
    'activeId': activeId,
    'profiles': profiles.map((p) => p.toJson()).toList(),
  };

  factory ProfilesState.fromJson(Map<String, dynamic> json) => ProfilesState(
    activeId: json['activeId'] as String?,
    profiles: ((json['profiles'] as List?) ?? const [])
        .map((e) => Profile.fromJson((e as Map).cast<String, dynamic>()))
        .toList(),
  );
}

/// A profile/config mutation was requested while the native VPN lifecycle was
/// between states. Applying it then could make the UI disagree with the
/// encrypted generation that is actually starting or stopping.
class ProfileMutationBusyException implements Exception {
  const ProfileMutationBusyException();
}

/// An active profile cannot be replaced/deleted while Android owns an
/// Always-on VPN lifecycle. The user must change that policy in system VPN
/// settings before Nozelt can safely drain the current configuration.
class ProfileMutationRequiresVpnStopException implements Exception {
  const ProfileMutationRequiresVpnStopException();
}
