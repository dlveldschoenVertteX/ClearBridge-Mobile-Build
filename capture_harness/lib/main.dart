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
  // Back to the mode chooser (not straight into 4-angle) so an arc-sweep
  // tester's "capture again" doesn't silently switch capture modes.
  _navigatorKey.currentState?.pushReplacement(
    MaterialPageRoute(builder: (_) => const _ModeChooserScreen()),
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
      // Splash -> mode chooser. The 4-angle flow is one tap away (was
      // previously entered directly); the chooser exists so the arc-sweep
      // (freehand) mode can be exercised from the same harness build.
      home: HarnessSplashScreen(
        onDone: () => _navigatorKey.currentState?.pushReplacement(
          MaterialPageRoute(builder: (_) => const _ModeChooserScreen()),
        ),
      ),
    );
  }
}

/// Minimal capture-mode chooser shown after the splash.
class _ModeChooserScreen extends StatelessWidget {
  const _ModeChooserScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CaptureColors.void_,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('MAC3D Harness',
                  style: CaptureTypography.h2
                      .copyWith(color: CaptureColors.silverBright)),
              const SizedBox(height: 40),
              CaptureButton(
                label: 'Standard 4-Angle Capture',
                leadingIcon: Icons.camera_alt,
                onPressed: () => _navigatorKey.currentState?.pushReplacement(
                  MaterialPageRoute(
                      builder: (_) => const _HarnessCaptureRoute()),
                ),
              ),
              const SizedBox(height: 16),
              CaptureButton(
                label: 'Arc Sweep (beta)',
                leadingIcon: Icons.threesixty,
                variant: CaptureButtonVariant.ghost,
                onPressed: () => _navigatorKey.currentState?.pushReplacement(
                  MaterialPageRoute(builder: (_) => const _HarnessArcRoute()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HarnessArcRoute extends StatelessWidget {
  const _HarnessArcRoute();

  @override
  Widget build(BuildContext context) {
    return ArcSweepCaptureScreen(
      uploader: const BackendCaptureUploader(),
      getUserId: () => FirebaseAuth.instance.currentUser?.uid,
      onRequireLogin: () => _restart(message: 'Auth expired — restarting'),
      onComplete: (captureId) => _navigatorKey.currentState?.pushReplacement(
        MaterialPageRoute(
          builder: (_) => LastCaptureReviewScreen(
            captureId: captureId,
            onCaptureAgain: _restart,
          ),
        ),
      ),
      onClose: () => _navigatorKey.currentState?.pushReplacement(
        MaterialPageRoute(builder: (_) => const _ModeChooserScreen()),
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
