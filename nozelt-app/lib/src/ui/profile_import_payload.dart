enum ProfileImportKind { subscription, links }

class ProfileImportException implements Exception {
  const ProfileImportException(this.messageKey);
  final String messageKey;
}

/// Classifies explicitly pasted/scanned links locally before any network call.
/// The payload is a credential: never include it in errors or logs.
class ProfileImportPayload {
  const ProfileImportPayload(this.kind, this.text);
  final ProfileImportKind kind;
  final String text;
  static const maxCharacters = 4 * 1024 * 1024;
  static const _proxySchemes = {
    'vless',
    'vmess',
    'trojan',
    'ss',
    'ssr',
    'tuic',
    'hysteria',
    'hysteria2',
    'hy2',
    'anytls',
    'socks',
    'socks5',
    'socks4',
  };

  static ProfileImportPayload parse(String? value) {
    if (value == null) {
      throw const ProfileImportException('importClipboardEmpty');
    }
    if (value.length > maxCharacters) {
      throw const ProfileImportException('proxyDataTooLarge');
    }
    if (value.trim().isEmpty) {
      throw const ProfileImportException('importClipboardEmpty');
    }
    final lines = value
        .trim()
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    final uri = Uri.tryParse(lines.first);
    if (lines.length == 1 && uri?.scheme.toLowerCase() == 'https') {
      if (uri!.host.isEmpty ||
          value.trim().length > 8192 ||
          RegExp(r'[\x00-\x20\x7f]').hasMatch(value.trim())) {
        throw const ProfileImportException('subscriptionInvalidUrl');
      }
      return ProfileImportPayload(ProfileImportKind.subscription, lines.first);
    }
    if (uri?.scheme.toLowerCase() == 'http') {
      throw const ProfileImportException('subscriptionHttpsRequired');
    }
    for (final line in lines) {
      final separator = line.indexOf('://');
      if (separator <= 0 ||
          separator + 3 == line.length ||
          !_proxySchemes.contains(line.substring(0, separator).toLowerCase()) ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(line)) {
        throw const ProfileImportException('importLinkUnsupported');
      }
    }
    return ProfileImportPayload(ProfileImportKind.links, lines.join('\n'));
  }
}
