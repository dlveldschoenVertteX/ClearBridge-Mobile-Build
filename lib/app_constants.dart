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
  static const String emailActionRoute = '/email-action';
  static const String logoPath = 'assets/images/app_logo.png';

  // Paystack Configuration
  // Provide these via --dart-define=PAYSTACK_PUBLIC_KEY=your_key
  static const String paystackPublicKey = String.fromEnvironment(
    'PAYSTACK_PUBLIC_KEY',
  );

  // Service Tiers (in ZAR)
  static const int priorityTierAmount = 530;
  static const int premiumTierAmount = 380;
}
