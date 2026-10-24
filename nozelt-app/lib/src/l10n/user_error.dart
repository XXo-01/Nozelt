import '../core/nozelt_engine.dart';
import '../core/config_error.dart';
import '../core/profile.dart';
import '../core/subscription_client.dart';
import '../data/profile_store.dart';
import '../data/sensitive_settings_repository.dart';
import 'nozelt_l10n.dart';

/// Names the VPN program that is using the network, when Windows told us.
String anotherVpnMessage(NozeltL10n l10n, Object? app) {
  final name = app?.toString().trim() ?? '';
  return name.isEmpty
      ? l10n.text('anotherVpnActive')
      : l10n.text('anotherVpnActiveNamed', {'app': name});
}

/// Converts internal exceptions to localized, secret-free text. Raw network
/// exceptions can embed credential-bearing URLs, so unknown errors are never
/// interpolated into user-facing widgets.
String localizedUserError(NozeltL10n l10n, Object error) {
  if (error is CoreConfigurationError) return l10n.text(error.l10nKey);
  if (error is SubscriptionException) {
    return l10n.text(error.l10nKey, {
      if (error.statusCode != null) 'status': error.statusCode!,
    });
  }
  if (error is ProfileStoreException) {
    return l10n.text('profilesUnavailable');
  }
  if (error is SensitiveSettingsStoreException) {
    return l10n.text('settingsUnavailable');
  }
  if (error is ProfileMutationBusyException) {
    return l10n.text('profileChangeBusy');
  }
  if (error is ProfileMutationRequiresVpnStopException) {
    return l10n.text('disableAlwaysOnFirst');
  }
  if (error is NozeltEngineException) {
    if (error.code == 'administrator_required') {
      return l10n.text('administratorRequired');
    }
    if (error.code == 'another_vpn_active') {
      return anotherVpnMessage(l10n, error.details);
    }
    if (error.code == 'network_guard_failed') {
      return l10n.text('networkGuardFailed');
    }
    if (error.code == 'tls_verification_required') {
      return l10n.text('windowsTlsVerificationRequired');
    }
    if (error.code == 'provider_process_rules_unsupported') {
      return l10n.text('windowsProviderProcessRulesUnsupported');
    }
    return l10n.text(
      error.code == 'parse_failed' ? 'proxyDataInvalid' : 'operationFailed',
      {'code': error.code},
    );
  }
  return l10n.text('unexpectedError');
}
