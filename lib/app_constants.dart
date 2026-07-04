class AppConstants {
  static const String appName = 'ClearBridge';
  static const String splashRoute = '/splash';
  static const String loginRoute = '/login';
  static const String otpRoute = '/otp';
  static const String dashboardRoute = '/dashboard';
  static const String captureRoute = '/capture';
  static const String paymentRoute = '/payment';
  static const String paymentProcessingRoute = '/payment/processing';
  static const String paymentSuccessRoute = '/payment/success';
  static const String paymentFailedRoute = '/payment/failed';
  static const String statusRoute = '/status';
  static const String historyRoute = '/history';
  static const String clearanceDetailsRoute = '/clearance-details';
  static const String notificationSettingsRoute = '/notification-settings';
  static const String pdfViewerRoute = '/pdf';
  static const String personalDetailsRoute = '/form';
  static const String networkErrorRoute = '/network-error';
  static const String selfieRoute = '/selfie';
  static const String idCaptureRoute = '/id-capture';
  static const String fingerprintRoute = '/fingerprint';
  static const String fingerprintReviewRoute = '/fingerprint/review';
  static const String fingerprintVideoProcessingRoute =
      '/fingerprint/video-processing';
  static const String fingerprintFrameSelectionRoute =
      '/fingerprint/frame-selection';
  static const String fingerprintPreviewRoute = '/fingerprint/preview';
  static const String fingerprintUploadRoute = '/fingerprint/upload';
  static const String popiaConsentRoute = '/popia';
  static const String serviceTierRoute = '/service-tier';
  static const String profileRoute = '/profile';
  static const String settingsRoute = '/settings';
  static const String adminRoute = '/admin';
  static const String adminLoginRoute = '/admin/login';
  static const String adminCapturesRoute = '/admin/captures';
  static const String adminPipelineRoute = '/admin/pipeline';
  static const String continuousCaptureRoute = '/capture/continuous';
  static const String arcSweepCaptureRoute = '/capture/arc';
  static const String clearCoinRewardRoute = '/clearcoin-reward';
  static const String betaThankYouRoute = '/beta-thank-you';
  static const String emailActionRoute = '/email-action';
  static const String logoPath = 'assets/images/clearbridge-logo-new.png';

  /// Selects which MAC3D capture flow this build targets. Set at build time
  /// via `--dart-define=CAPTURE_MODE=arcSweep` (the `fourAngle` flavor omits
  /// it and gets the default). Both flows stay fully wired in the router —
  /// this only decides which one every "start/retry capture" call site in
  /// the app routes to, so the two flavors share 100% of the flow code and
  /// can never drift out of sync with each other.
  static const String captureMode = String.fromEnvironment(
    'CAPTURE_MODE',
    defaultValue: 'fourAngle',
  );

  static bool get isArcSweepBuild => captureMode == 'arcSweep';

  /// The capture route this build should use everywhere it needs to send
  /// the user to "start a MAC3D capture" — splash-flow entry, dashboard's
  /// "start capture", capture-result's retry/retake, and the beta
  /// thank-you screen's "Capture again".
  static String get activeCaptureRoute =>
      isArcSweepBuild ? arcSweepCaptureRoute : continuousCaptureRoute;

  /// The actual Android applicationId for this build — must match
  /// android/app/build.gradle.kts's productFlavors (arcSweep gets the
  /// ".arcsweep" applicationIdSuffix). Used wherever Firebase Auth needs the
  /// exact package name (e.g. ActionCodeSettings for email links), since a
  /// mismatch there causes Firebase to reject the request.
  static String get androidPackageName =>
      isArcSweepBuild ? 'com.clearbridge.app.arcsweep' : 'com.clearbridge.app';

  // Paystack Configuration
  // Provide these via --dart-define=PAYSTACK_PUBLIC_KEY=your_key
  static const String paystackPublicKey = String.fromEnvironment(
    'PAYSTACK_PUBLIC_KEY',
  );

  // Service Tiers (in ZAR)
  static const int priorityTierAmount = 530;
  static const int premiumTierAmount = 380;
}
