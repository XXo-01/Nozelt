import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/core/nozelt_engine.dart';
import 'package:nozelt/src/core/subscription_client.dart';
import 'package:nozelt/src/core/profile.dart';
import 'package:nozelt/src/data/sensitive_settings_repository.dart';
import 'package:nozelt/src/l10n/nozelt_l10n.dart';
import 'package:nozelt/src/l10n/user_error.dart';

void main() {
  test('engine exception string is safe for crash logs', () {
    const error = NozeltEngineException(
      method: 'start',
      code: 'start_failed',
      message: 'https://user:secret@vpn.example/private-token',
      details: {'config': 'password=secret'},
    );

    expect(error.toString(), 'NozeltEngineException(start, start_failed)');
    expect(error.toString(), isNot(contains('secret')));
    expect(error.toString(), isNot(contains('vpn.example')));
  });

  test('localizes subscription errors without exposing internal text', () {
    const error = SubscriptionException(
      'internal English message with secret-token',
      l10nKey: 'subscriptionHttpsRequired',
    );

    final message = localizedUserError(NozeltL10n('ru'), error);
    expect(message, 'URL подписки должен использовать HTTPS.');
    expect(message, isNot(contains('secret-token')));
  });

  test('unknown exceptions are collapsed to a localized generic message', () {
    final message = localizedUserError(
      NozeltL10n('en'),
      Exception('https://panel.example/sub/secret-token'),
    );
    expect(message, 'An unexpected error occurred.');
    expect(message, isNot(contains('secret-token')));
  });

  test('profile transition errors have a safe localized message', () {
    final message = localizedUserError(
      NozeltL10n('en'),
      const ProfileMutationBusyException(),
    );

    expect(message, 'Wait for the VPN transition to finish and try again.');
  });

  test('always-on profile mutations explain the required system action', () {
    final message = localizedUserError(
      NozeltL10n('en'),
      const ProfileMutationRequiresVpnStopException(),
    );

    expect(message, contains('Disable Always-on VPN'));
  });

  test('secure settings failures expose no platform implementation detail', () {
    final message = localizedUserError(
      NozeltL10n('ru'),
      const SensitiveSettingsStoreException(),
    );

    expect(message, contains('Защищённое хранилище настроек'));
  });
}
