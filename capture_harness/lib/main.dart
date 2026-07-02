import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mac_capture/mac_capture.dart';

import 'backend_capture_uploader.dart';
import 'firebase_options.dart';
import 'harness_splash_screen.dart';
import 'last_capture_review_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Anonymous auth so Firestore/Storage security rules (which require
  // request.auth.uid == userId) are satisfied without a full login flow.
  await FirebaseAuth.instance.signInAnonymously();
  runApp(const ProviderScope(child: CaptureHarnessApp()));
}

/// Global keys so navigation/snackbars work from any callback regardless of
/// which route is currently mounted -- a route-captured BuildContext goes
/// stale the moment that route is replaced (e.g. a "capture again" callback
/// handed to a screen pushed *after* the route that created the callback).
final _navigatorKey = GlobalKey<NavigatorState>();
final _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

void _restart({String? message}) {
  _navigatorKey.currentState?.pushReplacement(
    MaterialPageRoute(builder: (_) => const _HarnessCaptureRoute()),
  );
  if (message != null) {
    _scaffoldMessengerKey.currentState
        ?.showSnackBar(SnackBar(content: Text(message)));
  }
}

class CaptureHarnessApp extends StatelessWidget {
  const CaptureHarnessApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClearBridge Beta',
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _scaffoldMessengerKey,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      // Splash -> straight into the capture flow. No intermediate
      // "Start capture" button screen -- beta testers open the app and are
      // immediately in MAC3D's own intro/start sequence.
      home: HarnessSplashScreen(
        onDone: () => _navigatorKey.currentState?.pushReplacement(
          MaterialPageRoute(builder: (_) => const _HarnessCaptureRoute()),
        ),
      ),
    );
  }
}

class _HarnessCaptureRoute extends StatelessWidget {
  const _HarnessCaptureRoute();

  @override
  Widget build(BuildContext context) {
    return MacCaptureScreen(
      uploader: const BackendCaptureUploader(),
      getUserId: () => FirebaseAuth.instance.currentUser?.uid,
      // Beta driver: always show the live gyro/CV/distance readout so capture
      // firing issues are diagnosable without a debugger attached.
      showDebugHud: true,
      onRequireLogin: () => _restart(),
      // Uploaded captures have a scoring pipeline to watch -- show the result
      // screen instead of immediately looping back into a new capture.
      onComplete: (captureId) => _navigatorKey.currentState?.pushReplacement(
        MaterialPageRoute(
          builder: (_) => LastCaptureReviewScreen(
            captureId: captureId,
            onCaptureAgain: _restart,
          ),
        ),
      ),
      onQueued: (captureId) => _restart(message: 'Queued offline: $captureId'),
      onClose: () => _restart(),
    );
  }
}
