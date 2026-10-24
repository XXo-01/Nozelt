import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'widgets/nozelt_ui.dart';
import 'package:http/http.dart' as http;

import '../l10n/nozelt_l10n.dart';

enum GeoTagKind { geoIp, geoSite }

class GeoTagsScreen extends StatefulWidget {
  const GeoTagsScreen({required this.kind, super.key});

  final GeoTagKind kind;

  @override
  State<GeoTagsScreen> createState() => _GeoTagsScreenState();
}

class _GeoTagsScreenState extends State<GeoTagsScreen> {
  late final Future<List<String>> _tags = _loadTags();
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  static const _fallbackGeoIp = [
    'ad',
    'ae',
    'am',
    'at',
    'au',
    'az',
    'be',
    'bg',
    'br',
    'by',
    'ca',
    'ch',
    'cn',
    'cz',
    'de',
    'dk',
    'ee',
    'es',
    'fi',
    'fr',
    'gb',
    'ge',
    'hk',
    'hu',
    'id',
    'ie',
    'il',
    'in',
    'ir',
    'is',
    'it',
    'jp',
    'kg',
    'kr',
    'kz',
    'lt',
    'lu',
    'lv',
    'md',
    'mx',
    'nl',
    'no',
    'nz',
    'pl',
    'private',
    'pt',
    'ro',
    'rs',
    'ru',
    'se',
    'sg',
    'sk',
    'th',
    'tr',
    'tw',
    'ua',
    'us',
    'uz',
    'vn',
  ];
  static const _fallbackGeoSite = [
    'ads',
    'apple',
    'category-ads-all',
    'category-ai-chat-!cn',
    'category-communication',
    'category-ecommerce',
    'category-entertainment',
    'category-dev',
    'category-games',
    'category-media',
    'category-news',
    'category-porn',
    'category-social-media-!cn',
    'category-speedtest',
    'category-vpnservices',
    'cloudflare',
    'discord',
    'facebook',
    'github',
    'google',
    'instagram',
    'microsoft',
    'netflix',
    'openai',
    'private',
    'reddit',
    'spotify',
    'telegram',
    'tiktok',
    'twitch',
    'twitter',
    'whatsapp',
    'youtube',
  ];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final desktop = Theme.of(context).platform == TargetPlatform.windows;
    final title = Text(
      context.tr(widget.kind == GeoTagKind.geoIp ? 'geoIpTags' : 'geoSiteTags'),
    );
    return Scaffold(
      appBar: desktop
          ? NozeltDesktopAppBar(title: title)
          : AppBar(title: title),
      body: NozeltEditorBody(
        child: NozeltPageInsets(
          builder: (context, insets) => FutureBuilder<List<String>>(
            future: _tags,
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final tags = snapshot.data!
                  .where((tag) => tag.toLowerCase().contains(_query))
                  .toList(growable: false);
              final groups = <String, List<String>>{};
              for (final tag in tags) {
                final letter = tag.characters.first.toUpperCase();
                groups.putIfAbsent(letter, () => []).add(tag);
              }
              return Column(
                children: [
                  Padding(
                    padding: desktop
                        ? EdgeInsets.fromLTRB(insets.left, 8, insets.right, 12)
                        : const EdgeInsets.fromLTRB(20, 8, 20, 12),
                    child: TextField(
                      key: const ValueKey('geo-tag-search'),
                      controller: _searchController,
                      onChanged: (value) =>
                          setState(() => _query = value.trim().toLowerCase()),
                      decoration: nozeltSearchDecoration(
                        context,
                        InputDecoration(
                          prefixIcon: const Icon(Icons.search_rounded),
                          hintText: context.tr('searchTags'),
                          suffixIcon: _query.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: context.tr('clearSearch'),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() => _query = '');
                                  },
                                  icon: const Icon(Icons.close_rounded),
                                ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: tags.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.search_off_rounded,
                                  size: 40,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  context.tr('noSearchResults'),
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            padding: desktop
                                ? EdgeInsets.fromLTRB(
                                    insets.left,
                                    4,
                                    insets.right,
                                    insets.bottom,
                                  )
                                : const EdgeInsets.fromLTRB(20, 4, 20, 28),
                            itemCount: groups.length,
                            itemBuilder: (context, index) {
                              final entry = groups.entries.elementAt(index);
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 18),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      entry.key,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge
                                          ?.copyWith(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                            fontWeight: FontWeight.w800,
                                          ),
                                    ),
                                    const SizedBox(height: 6),
                                    Wrap(
                                      spacing: 7,
                                      runSpacing: 7,
                                      children: [
                                        for (final tag in entry.value)
                                          ActionChip(
                                            backgroundColor:
                                                defaultTargetPlatform ==
                                                    TargetPlatform.windows
                                                ? Theme.of(context)
                                                      .colorScheme
                                                      .surfaceContainerHighest
                                                : null,
                                            side:
                                                defaultTargetPlatform ==
                                                    TargetPlatform.windows
                                                ? BorderSide(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .outlineVariant,
                                                  )
                                                : null,
                                            shape:
                                                defaultTargetPlatform ==
                                                    TargetPlatform.windows
                                                ? const StadiumBorder()
                                                : null,
                                            label: Text(tag),
                                            onPressed: () =>
                                                Navigator.of(context).pop(
                                                  '${widget.kind == GeoTagKind.geoIp ? 'geoip' : 'geosite'}:$tag',
                                                ),
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Future<List<String>> _loadTags() async {
    final (repository, branch, prefix) = switch (widget.kind) {
      GeoTagKind.geoIp => ('SagerNet/sing-geoip', 'rule-set', 'geoip-'),
      GeoTagKind.geoSite => ('SagerNet/sing-geosite', 'rule-set', 'geosite-'),
    };
    try {
      final response = await http
          .get(
            Uri.parse(
              'https://api.github.com/repos/$repository/git/trees/$branch?recursive=1',
            ),
            headers: const {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200 ||
          response.body.length > 8 * 1024 * 1024) {
        throw const FormatException('tag catalog unavailable');
      }
      final root = jsonDecode(response.body);
      final tree = root is Map ? root['tree'] : null;
      if (tree is! List) throw const FormatException('invalid tag catalog');
      final tags =
          tree
              .whereType<Map>()
              .map((entry) => entry['path']?.toString() ?? '')
              .where((path) => path.startsWith(prefix) && path.endsWith('.srs'))
              .map((path) => path.substring(prefix.length, path.length - 4))
              .where((tag) => tag.isNotEmpty)
              .toSet()
              .toList(growable: false)
            ..sort();
      if (tags.isNotEmpty) return tags;
    } catch (_) {
      // The embedded fallback keeps the editor useful on filtered networks.
    }
    return List.unmodifiable(
      widget.kind == GeoTagKind.geoIp ? _fallbackGeoIp : _fallbackGeoSite,
    );
  }
}
