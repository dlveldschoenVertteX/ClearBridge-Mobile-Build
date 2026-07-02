import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mac_capture/mac_capture.dart';

import 'backend_capture_uploader.dart';
import 'firebase_options.dart';
import 'harness_splash_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Anonymous auth so Firestore/Storage security rules (which require
  // request.auth.uid == userId) are satisfied without a full login flow.
  await FirebaseAuth.instance.signInAnonymously();
  runApp(const ProviderScope(child: CaptureHarnessApp()));
}

/// Survives route replacement (splash -> capture -> next capture) so result
/// snackbars still show even though the widget under them just got swapped.
final _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

class CaptureHarnessApp extends StatelessWidget {
  const CaptureHarnessApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MAC3D Capture Harness',
      scaffoldMessengerKey: _scaffoldMessengerKey,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      // Splash -> straight into the capture flow. No intermediate
      // "Start capture" button screen -- beta testers open the app and are
      // immediately in MAC3D's own intro/start sequence.
      home: Builder(
        builder: (context) => HarnessSplashScreen(
          onDone: () => Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const _HarnessCaptureRoute()),
          ),
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
      onRequireLogin: () => _restart(context),
      onComplete: (captureId) => _restart(context, message: 'Uploaded: $captureId'),
      onQueued: (captureId) => _restart(context, message: 'Queued offline: $captureId'),
      onClose: () => _restart(context),
    );
  }

  /// There's no home screen to pop back to anymore -- loop straight into a
  /// fresh capture session (MacCaptureScreen's controller is autoDispose, so
  /// re-pushing this route gives a clean state machine each time).
  void _restart(BuildContext context, {String? message}) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const _HarnessCaptureRoute()),
    );
    if (message != null) {
      _scaffoldMessengerKey.currentState
          ?.showSnackBar(SnackBar(content: Text(message)));
    }
  }
}
