import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'core/services/connectivity_service.dart';
import 'core/services/deep_link_service.dart';
import 'core/services/router_service.dart';
import 'core/services/sync_service.dart';
import 'core/theme/app_theme.dart';
import 'core/constants/app_constants.dart';
import 'core/services/notification_service.dart';
import 'firebase_options.dart';

void main() async {
  if (kIsWeb) usePathUrlStrategy();
  WidgetsFlutterBinding.ensureInitialized();

  // Console-only handler until Crashlytics is wired up in _bootstrap().
  FlutterError.onError = FlutterError.presentError;

  runApp(const ProviderScope(child: _BootstrapperApp()));
}

Future<void> _initializeFirebaseWithRetry() async {
  // Some devices occasionally report a transient channel error at cold start in
  // release builds. Retrying a couple times avoids a hard failure.
  const delays = <Duration>[
    Duration.zero,
    Duration(milliseconds: 300),
  ];

  Object? lastError;
  for (final delay in delays) {
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }

    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      return;
    } catch (error) {
      lastError = error;

      if (error is PlatformException && error.code == 'channel-error') {
        debugPrint(
          'Firebase init channel-error, retrying (delay=${delay.inMilliseconds}ms): ${error.message}',
        );
        continue;
      }
      rethrow;
    }
  }

  if (lastError != null) {
    throw lastError;
  }
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    // Keep connectivity monitor + offline upload sync alive for the app lifetime.
    ref.watch(connectivityServiceProvider);
    ref.watch(syncServiceProvider);
    ref.watch(deepLinkServiceProvider);

    // Link NotificationService with router for navigation
    NotificationService.setRouter(router);

    return MaterialApp.router(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      routerConfig: router,
    );
  }
}

class _BootstrapperApp extends StatefulWidget {
  const _BootstrapperApp();

  @override
  State<_BootstrapperApp> createState() => _BootstrapperAppState();
}

class _BootstrapperAppState extends State<_BootstrapperApp> {
  late final Future<void> _bootstrapFuture;
  final Completer<void> _bootstrapCompleter = Completer<void>();

  @override
  void initState() {
    super.initState();
    _bootstrapFuture = _bootstrapCompleter.future;

    // Some release builds/devices can throw a transient firebase_core
    // "channel-error" if initialization happens immediately at startup.
    // Waiting for the first frame ensures the FlutterEngine + plugins are fully
    // attached before we call into Pigeon channels.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await _bootstrap();
        if (!_bootstrapCompleter.isCompleted) {
          _bootstrapCompleter.complete();
        }
      } catch (error, stack) {
        if (!_bootstrapCompleter.isCompleted) {
          _bootstrapCompleter.completeError(error, stack);
        }
      }
    });
  }

  Future<void> _bootstrap() async {
    // Firebase init and notification setup are independent — run in parallel.
    await Future.wait([
      _initializeFirebaseWithRetry(),
      NotificationService.init(),
    ]);

    // App Check: Play Integrity on Android (attests the APK is a genuine signed
    // build). Runs silently in the background; tokens are attached automatically
    // to all Firebase SDK requests (Firestore, Storage, Cloud Functions callable).
    // Enforcement is enabled per-service in the Firebase Console → App Check.
    // Use AndroidProvider.debug for emulator/CI; playIntegrity for release builds.
    if (!kIsWeb) {
      await FirebaseAppCheck.instance.activate(
        androidProvider: kDebugMode // ignore: deprecated_member_use
            ? AndroidProvider.debug
            : AndroidProvider.playIntegrity,
      );
    }

    // Enable Firestore offline persistence so dashboard/history serve cached
    // data when the device has no connectivity.
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: true,
      cacheSizeBytes: 50 * 1024 * 1024, // 50 MB cap — prevents unbounded growth
    );

    // Crashlytics requires Firebase. Wire up both the Flutter-layer handler
    // (widget build / framework errors) and the Dart-layer handler (async
    // errors that escape the Flutter framework).
    if (!kIsWeb) {
      FlutterError.onError =
          FirebaseCrashlytics.instance.recordFlutterFatalError;
      PlatformDispatcher.instance.onError = (error, stack) {
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
        return true;
      };
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _bootstrapFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.darkTheme,
            home: const Scaffold(
              backgroundColor: Colors.black,
              body: SafeArea(
                child: Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              ),
            ),
          );
        }

        final error = snapshot.error;
        if (error != null) {
          debugPrint('Firebase initialization failed: $error');
          return const _BootstrapFailedApp(
            message:
                'Firebase failed to initialize. Please reinstall the app or check Google Play services.',
          );
        }

        return const MyApp();
      },
    );
  }
}

class _BootstrapFailedApp extends StatelessWidget {
  final String message;

  const _BootstrapFailedApp({required this.message});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
