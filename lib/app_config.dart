class AppConfig {
  // Controlled via --dart-define=FLUTTER_BETA_MODE=true|false at build time.
  // Default is true so debug/CI builds are always safe.
  // Production release must pass --dart-define=FLUTTER_BETA_MODE=false.
  static const bool isBeta =
      bool.fromEnvironment('FLUTTER_BETA_MODE', defaultValue: true);

  // When isBeta = true:
  // - AFIS submission disabled (data collected, not submitted)
  // - Paystack payment disabled (R50 credit shown instead)
  // - Workers see "Beta Credit" instead of "Clearance Processing"

  // When isBeta = false (production):
  // - Full AFIS submission enabled
  // - Full Paystack payment enabled
  // - Workers see clearance status
}
