/// Controlled, credential-free configuration errors that can reach the UI.
class CoreConfigurationError extends StateError {
  CoreConfigurationError(this.l10nKey, super.message);

  final String l10nKey;
}
