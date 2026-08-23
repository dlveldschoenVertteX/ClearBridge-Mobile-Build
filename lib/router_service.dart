import 'package:go_router/go_router.dart';
import 'package:flutter_web_plugins/url_strategy.dart' show urlStrategy;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:mac_capture/mac_capture.dart';

import 'package:clearbridge/app_constants.dart';
import 'package:clearbridge/fingerprint_frame_upload_service.dart';
import 'package:clearbridge/splash_screen.dart';
import 'package:clearbridge/phone_login_screen.dart';
import 'package:clearbridge/otp_verification_screen.dart';
import 'package:clearbridge/dashboard_screen.dart';
import 'package:clearbridge/payment_screen.dart';
import 'package:clearbridge/payment_processing_screen.dart';
import 'package:clearbridge/payment_success_screen.dart';
import 'package:clearbridge/payment_failed_screen.dart';
import 'package:clearbridge/status_screen.dart';
import 'package:clearbridge/history_screen.dart';
import 'package:clearbridge/pdf_viewer_screen.dart';
import 'package:clearbridge/service_tier_screen.dart';
import 'package:clearbridge/personal_details_screen.dart';
import 'package:clearbridge/popia_consent_screen.dart';
import 'package:clearbridge/popia_consent_screen.dart' as capture_popia;
import 'package:clearbridge/capture_result_screen.dart';
import 'package:clearbridge/privacy_policy_screen.dart';
import 'package:clearbridge/profile_screen.dart';
import 'package:clearbridge/auth_provider.dart';
import 'package:clearbridge/main_shell.dart';
import 'package:clearbridge/clearance_provider.dart';
import 'package:clearbridge/clearance_model.dart';

import 'package:clearbridge/user_profile_provider.dart'
    show userProfileCompletedProvider, captureConsentProvider;
// Provided isFingerprintOnlyProvider for the selfie/fingerprint branch —
// unused while Selfie + ID capture are removed from the Beta flow (2026-06-02).
// import '../../features/application/providers/application_flow_provider.dart';
import 'router_refresh_notifier.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:clearbridge/network_error_screen.dart';
import 'package:clearbridge/admin_auth_guard.dart';
import 'package:clearbridge/admin_dashboard_screen.dart';
import 'package:clearbridge/admin_login_screen.dart';
import 'package:clearbridge/captures_screen.dart';
import 'package:clearbridge/pipeline_health_screen.dart';
import 'package:clearbridge/clearcoin_reward_screen.dart';
import 'package:clearbridge/beta_thank_you_screen.dart';
import 'package:clearbridge/email_action_screen.dart';
part 'router_service.g.dart';

/// Wires the standalone mac_capture package's MacCaptureScreen up to this
/// app's Firebase auth, Firestore-backed uploader, and go_router navigation
/// -- the package itself has no dependency on any of the three.
Widget _macCaptureScreen(BuildContext context) {
  return MacCaptureScreen(
    uploader: const FingerprintFrameUploadService(),
    getUserId: () => FirebaseAuth.instance.currentUser?.uid,
    onRequireLogin: () => context.go(AppConstants.loginRoute),
    onComplete: (captureId) =>
        context.go('/capture/result', extra: captureId),
    onQueued: (captureId) => context.go('/capture/result', extra: {
      'captureId': captureId,
      'queued': true,
    }),
    onClose: () {
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(AppConstants.dashboardRoute);
      }
    },
  );
}

@riverpod
GoRouter router(Ref ref) {
  final refreshNotifier = ref.watch(routerRefreshNotifierProvider);

  // On web, start at the actual browser URL so direct navigation to /admin/*
  // works correctly. Without this, GoRouter starts at initialLocation (/splash)
  // because the _BootstrapperApp loading phase delays router creation, and the
  // SplashScreen then redirects unauthenticated users to /login.
  //
  // REAL BUG FIXED: this used to read `Uri.base.path` directly -- the raw
  // browser window.location.pathname, with no awareness of the page's own
  // <base href>. That is only correct when the app is deployed at the site
  // ROOT (base href "/"). This app is also deployed under a subpath (the
  // admin panel, at /admin_panel/ -- see deploy-web in
  // .github/workflows/build.yml), where a URL like
  // /admin_panel/admin would read as browserPath "/admin_panel/admin", which
  // matches none of this router's own routes (all declared relative to the
  // app's base, e.g. "/admin", "/admin/login") -- GoRouter would fail to
  // match it and fall through to its default not-found handling instead of
  // ever reaching AdminLoginScreen/AdminDashboardScreen. `urlStrategy` (set
  // by usePathUrlStrategy() in main.dart, already running by the time this
  // provider is first read) exposes `getPath()`, the SAME base-href-aware
  // accessor GoRouter's own Router widget uses internally to reconcile
  // subsequent browser navigation -- using it here instead makes the FIRST
  // (cold-start) read consistent with every later one.
  final browserPath = kIsWeb
      ? (urlStrategy?.getPath() ?? Uri.base.path)
      : '';
  final initialLocation = (browserPath.isEmpty || browserPath == '/')
      ? AppConstants.splashRoute
      : browserPath;

  return GoRouter(
    initialLocation: initialLocation,
    refreshListenable: refreshNotifier,
    redirect: (context, state) {
      final path = state.uri.path;

      // Admin routes: enforce the admin custom claim at the router level.
      // /admin/login is always reachable; all other /admin/* paths require
      // the claim to be confirmed before the screen is allowed to mount.
      if (path.startsWith('/admin')) {
        if (path == AppConstants.adminLoginRoute) return null;
        final claim = ref.read(adminClaimProvider);
        return claim.when(
          data: (isAdmin) => isAdmin ? null : AppConstants.adminLoginRoute,
          // Still resolving — allow through; router re-evaluates when
          // adminClaimProvider completes and notifies routerRefreshNotifier.
          loading: () => null,
          error: (_, __) => AppConstants.adminLoginRoute,
        );
      }

      // Skip redirect for splash screen - let it handle navigation
      if (path == AppConstants.splashRoute) {
        return null;
      }

      // Email action links (verify, reset, recover) must be reachable in any
      // auth state — password reset is used when the user is logged out.
      if (path == '/__/auth/action' || path == AppConstants.emailActionRoute) {
        return null;
      }

      final authState = ref.read(authProvider);
      if (authState.isLoading) return null;

      final user = authState.valueOrNull;
      final isLoggedOut = user == null;

      final isAuthRoute =
          path == AppConstants.loginRoute ||
          path == AppConstants.otpRoute;

      final isPaymentRoute =
          path == AppConstants.paymentRoute ||
          path == AppConstants.paymentProcessingRoute ||
          path == AppConstants.paymentSuccessRoute ||
          path == AppConstants.paymentFailedRoute;

      final profileCompletedState = ref.read(userProfileCompletedProvider);

      debugPrint(
        'Router (Redirect): Loc=$path, User=${user?.uid}, ProfileCompletedStatus=${profileCompletedState.toString()}',
      );

      if (isLoggedOut) {
        if (!isAuthRoute) {
          return AppConstants.loginRoute;
        }
        return null;
      }

      // Handle loading and error states for profile completion
      if (profileCompletedState.isLoading) return null;

      if (profileCompletedState.hasError) {
        final error = profileCompletedState.error;
        debugPrint('Router: Profile checking error: $error');

        bool isNetworkError = false;
        if (error is FirebaseException) {
          // Detect common network-related Firestore errors
          isNetworkError =
              error.code == 'unavailable' ||
              error.code == 'deadline-exceeded' ||
              error.message?.toLowerCase().contains('network') == true;
        }

        if (isNetworkError) {
          // Dashboard, history, and profile serve Firestore cached data offline
          // — don't redirect them to the error screen. Other routes (payment,
          // capture result) need a live connection and do redirect.
          const safeOfflineRoutes = {
            '/dashboard',
            '/history',
            '/profile',
          };
          if (path != AppConstants.networkErrorRoute &&
              !safeOfflineRoutes.contains(path)) {
            return AppConstants.networkErrorRoute;
          }
          return null;
        }

        // For permission-denied or other auth-related errors, the provider
        // will automatically sign out the user, so we just wait for that
        debugPrint(
          'Router: Auth-related error detected, waiting for automatic sign-out',
        );
        return null;
      }

      final isProfileCompleted = profileCompletedState.valueOrNull ?? false;

      // Gate new users through POPIA consent before the personal details form.
      if (!isProfileCompleted) {
        if (path != AppConstants.personalDetailsRoute &&
            path != AppConstants.popiaConsentRoute) {
          return AppConstants.popiaConsentRoute;
        }
        return null;
      }

      // Gate capture routes behind the biometric (POPIA v2.0) consent screen.
      // The BetaConsentScreen at /popia-consent writes consents.captureConsent
      // to Firestore on completion; captureConsentProvider streams that field.
      const captureRoutes = {
        AppConstants.fingerprintRoute,
        AppConstants.continuousCaptureRoute,
        AppConstants.arcSweepCaptureRoute,
      };
      if (captureRoutes.contains(path)) {
        final consentState = ref.read(captureConsentProvider);
        final hasConsent = consentState.valueOrNull ?? false;
        if (!hasConsent) return '/popia-consent';
      }

      // User logged in and profile completed.
      //
      // NOTE: we intentionally do NOT force `/form` → `/fingerprint` here.
      // Onboarding advances itself — `PersonalDetailsScreen._submit()` calls
      // `context.go(dashboardRoute)` on success — so this redirect never helped
      // the signup flow; it only fired when an already-onboarded user opened
      // "Personal Info" from Profile to edit their details, bouncing them into
      // the capture screen. Editing now correctly shows the details form.

      if (isAuthRoute ||
          path == AppConstants.splashRoute ||
          path == AppConstants.networkErrorRoute) {
        // Don't redirect if user is on a payment-related route
        if (!isPaymentRoute) {
          debugPrint('Router: Redirecting to Dashboard from $path');
          return AppConstants.dashboardRoute;
        }
      }

      debugPrint('Router: Staying at $path');
      return null;
    },
    routes: [
      // Shell routes for main app with bottom navigation
      ShellRoute(
        builder: (context, state, child) => MainShell(child: child),
        routes: [
          GoRoute(
            path: AppConstants.dashboardRoute,
            builder: (context, state) => const DashboardScreen(),
          ),
          GoRoute(
            path: AppConstants.historyRoute,
            builder: (context, state) => const HistoryScreen(),
          ),
          GoRoute(
            path: '${AppConstants.clearanceDetailsRoute}/:id',
            builder: (context, state) {
              final id = state.pathParameters['id'];
              return _ClearanceDetailsRouteScreen(clearanceId: id);
            },
          ),
          GoRoute(
            path: '/profile',
            builder: (context, state) => const ProfileScreen(),
          ),
        ],
      ),
      // Standalone routes (no bottom nav)
      GoRoute(
        path: AppConstants.splashRoute,
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: AppConstants.networkErrorRoute,
        builder: (context, state) => const NetworkErrorScreen(),
      ),
      GoRoute(
        path: AppConstants.loginRoute,
        builder: (context, state) => const PhoneLoginScreen(),
      ),
      GoRoute(
        path: AppConstants.otpRoute,
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>?;
          return OtpVerificationScreen(
            phoneNumber: extra?['phoneNumber'] as String? ?? '',
            verificationId: extra?['verificationId'] as String? ?? '',
            referralCode: extra?['referralCode'] as String? ?? '',
          );
        },
      ),
      GoRoute(
        path: AppConstants.popiaConsentRoute,
        builder: (context, state) => const BetaConsentScreen(),
      ),
      GoRoute(
        path: '/popia-consent',
        name: 'popiaConsent',
        builder: (context, state) => const capture_popia.BetaConsentScreen(),
      ),
      GoRoute(
        path: '/privacy',
        builder: (context, state) => const PrivacyPolicyScreen(),
      ),
      GoRoute(
        path: AppConstants.personalDetailsRoute,
        builder: (context, state) => const PersonalDetailsScreen(),
      ),
      GoRoute(
        path: AppConstants.serviceTierRoute,
        builder: (context, state) => const ServiceTierScreen(),
      ),
      GoRoute(
        path: AppConstants.fingerprintRoute,
        builder: (context, state) => _macCaptureScreen(context),
      ),
      GoRoute(
        path: AppConstants.continuousCaptureRoute,
        name: 'continuousCapture',
        builder: (context, state) => _macCaptureScreen(context),
      ),
      GoRoute(
        path: AppConstants.arcSweepCaptureRoute,
        name: 'arcSweepCapture',
        builder: (context, state) => ArcSweepCaptureScreen(
          uploader: const FingerprintFrameUploadService(),
          getUserId: () => FirebaseAuth.instance.currentUser?.uid,
          onRequireLogin: () => context.go(AppConstants.loginRoute),
          onComplete: (captureId) =>
              context.go('/capture/result', extra: captureId),
          onClose: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go(AppConstants.dashboardRoute);
            }
          },
        ),
      ),
      GoRoute(
        path: '/capture/result',
        name: 'captureResult',
        builder: (context, state) {
          final extra = state.extra;
          if (extra is Map) {
            return CaptureResultScreen(
              captureId: extra['captureId'] as String,
              isQueued: extra['queued'] as bool? ?? false,
            );
          }
          return CaptureResultScreen(captureId: extra as String);
        },
      ),
      GoRoute(
        path: AppConstants.paymentRoute,
        builder: (context, state) => const PaymentScreen(),
      ),
      GoRoute(
        path: AppConstants.paymentProcessingRoute,
        builder: (context, state) => const PaymentProcessingScreen(),
      ),
      GoRoute(
        path: AppConstants.paymentSuccessRoute,
        builder: (context, state) => const PaymentSuccessScreen(),
      ),
      GoRoute(
        path: AppConstants.paymentFailedRoute,
        builder: (context, state) => const PaymentFailedScreen(),
      ),
      GoRoute(
        path: AppConstants.statusRoute,
        builder: (context, state) => const StatusScreen(),
      ),
      GoRoute(
        path: AppConstants.pdfViewerRoute,
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>?;
          return PDFViewerScreen(
            certificateUrl: extra?['url'] as String? ?? '',
            reference: extra?['reference'] as String? ?? 'DOC',
          );
        },
      ),
      // Admin routes (web panel)
      GoRoute(
        path: AppConstants.clearCoinRewardRoute,
        name: 'clearCoinReward',
        builder: (context, state) => const ClearCoinRewardScreen(),
      ),
      GoRoute(
        path: AppConstants.betaThankYouRoute,
        name: 'betaThankYou',
        builder: (context, state) => const BetaThankYouScreen(),
      ),
      // Firebase Auth email action URL — Android App Links cold-start +
      // Flutter web. iOS cold-start is handled by DeepLinkService.getInitialLink.
      GoRoute(
        path: '/__/auth/action',
        name: 'firebaseAuthAction',
        builder: (context, state) => EmailActionScreen(
          mode: state.uri.queryParameters['mode'] ?? '',
          oobCode: state.uri.queryParameters['oobCode'] ?? '',
        ),
      ),
      // Internal route used by DeepLinkService for hot-start navigation.
      GoRoute(
        path: AppConstants.emailActionRoute,
        name: 'emailAction',
        builder: (context, state) => EmailActionScreen(
          mode: state.uri.queryParameters['mode'] ?? '',
          oobCode: state.uri.queryParameters['oobCode'] ?? '',
        ),
      ),
      GoRoute(
        path: AppConstants.adminLoginRoute,
        builder: (context, state) => const AdminLoginScreen(),
      ),
      GoRoute(
        path: AppConstants.adminRoute,
        builder: (context, state) => const AdminDashboardScreen(),
      ),
      GoRoute(
        path: AppConstants.adminCapturesRoute,
        builder: (context, state) => const CapturesScreen(),
      ),
      GoRoute(
        path: AppConstants.adminPipelineRoute,
        builder: (context, state) => const PipelineHealthScreen(),
      ),
    ],
  );
}

class _ClearanceDetailsRouteScreen extends ConsumerStatefulWidget {
  const _ClearanceDetailsRouteScreen({required this.clearanceId});

  final String? clearanceId;

  @override
  ConsumerState<_ClearanceDetailsRouteScreen> createState() =>
      _ClearanceDetailsRouteScreenState();
}

class _ClearanceDetailsRouteScreenState
    extends ConsumerState<_ClearanceDetailsRouteScreen> {
  bool _hasResolvedSelection = false;

  @override
  Widget build(BuildContext context) {
    if (!_hasResolvedSelection) {
      ref.listen<AsyncValue<List<ClearanceModel>>>(userClearancesProvider, (
        _,
        next,
      ) {
        if (!mounted || _hasResolvedSelection) return;

        next.whenData((clearances) {
          if (!mounted || _hasResolvedSelection) return;

          final clearanceId = widget.clearanceId;
          ClearanceModel? matchedClearance;
          if (clearanceId != null) {
            for (final clearance in clearances) {
              if (clearance.clearanceId == clearanceId) {
                matchedClearance = clearance;
                break;
              }
            }
          }

          _hasResolvedSelection = true;

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;

            if (matchedClearance != null) {
              ref
                  .read(selectedClearanceIdProvider.notifier)
                  .set(matchedClearance.clearanceId);
              return;
            }

            ref.read(selectedClearanceIdProvider.notifier).set(null);
            if (GoRouterState.of(context).matchedLocation !=
                AppConstants.dashboardRoute) {
              context.go(AppConstants.dashboardRoute);
            }
          });
        });
      });
    }

    return const DashboardScreen();
  }
}
