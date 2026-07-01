import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../constants/app_constants.dart';
import '../../features/auth/screens/splash_screen.dart';
import '../../features/auth/screens/phone_login_screen.dart';
import '../../features/auth/screens/otp_verification_screen.dart';
import '../../features/dashboard/screens/dashboard_screen.dart';
import '../../features/payment/screens/payment_screen.dart';
import '../../features/payment/screens/payment_processing_screen.dart';
import '../../features/payment/screens/payment_success_screen.dart';
import '../../features/payment/screens/payment_failed_screen.dart';
import '../../features/payment/screens/status_screen.dart';
import '../../features/history/screens/history_screen.dart';
import '../../features/history/screens/pdf_viewer_screen.dart';
import '../../features/capture/screens/service_tier_screen.dart';
import '../../features/application/screens/personal_details_screen.dart';
import '../../features/capture/screens/mac_capture_screen.dart';
import '../../features/auth/screens/popia_consent_screen.dart';
import '../../features/capture/screens/popia_consent_screen.dart' as capture_popia;
import '../../features/capture/screens/capture_result_screen.dart';
import '../../features/privacy/screens/privacy_policy_screen.dart';
import '../../features/profile/screens/profile_screen.dart';
import '../../features/auth/providers/auth_provider.dart';
import '../../shared/widgets/main_shell.dart';
import '../../features/application/providers/clearance_provider.dart';
import '../../features/application/models/clearance_model.dart';

import '../../features/auth/providers/user_profile_provider.dart'
    show userProfileCompletedProvider, captureConsentProvider;
// Provided isFingerprintOnlyProvider for the selfie/fingerprint branch —
// unused while Selfie + ID capture are removed from the Beta flow (2026-06-02).
// import '../../features/application/providers/application_flow_provider.dart';
import 'router_refresh_notifier.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import '../../shared/widgets/network_error_screen.dart';
import '../../admin/admin_auth_guard.dart';
import '../../admin/screens/admin_dashboard_screen.dart';
import '../../admin/screens/admin_login_screen.dart';
import '../../admin/screens/captures_screen.dart';
import '../../admin/screens/pipeline_health_screen.dart';
import '../../features/clearcoin/screens/clearcoin_reward_screen.dart';
import '../../features/auth/screens/email_action_screen.dart';
part 'router_service.g.dart';

@riverpod
GoRouter router(Ref ref) {
  final refreshNotifier = ref.watch(routerRefreshNotifierProvider);

  // On web, start at the actual browser URL so direct navigation to /admin/*
  // works correctly. Without this, GoRouter starts at initialLocation (/splash)
  // because the _BootstrapperApp loading phase delays router creation, and the
  // SplashScreen then redirects unauthenticated users to /login.
  final browserPath = kIsWeb ? Uri.base.path : '';
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
        builder: (context, state) => const PopiaConsentScreen(),
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
        builder: (context, state) => const MacCaptureScreen(),
      ),
      GoRoute(
        path: AppConstants.continuousCaptureRoute,
        name: 'continuousCapture',
        builder: (context, state) => const MacCaptureScreen(),
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
