import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:clearbridge_beta/beta_thank_you_screen.dart';
import 'package:clearbridge_beta/camera_probe_screen.dart';
import 'package:clearbridge_beta/clearbridge_colors.dart';
import 'package:clearbridge_beta/clearcoin_screen.dart';
import 'package:clearbridge_beta/firebase_options.dart';
import 'package:clearbridge_beta/front_capture_screen.dart';
import 'package:clearbridge_beta/splash_screen.dart';
import 'package:clearbridge_beta/user_details_popia_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Firebase/auth failures (e.g. network-less first launch, API key
  // restrictions) must not stop the UI from ever appearing — anything
  // thrown here previously crashed the app before runApp() ran.
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    // Anonymous auth so Firestore/Storage security rules (which require
    // request.auth.uid == userId) are satisfied without a full login flow.
    // See user_details_popia_screen.dart for the phone-number field collected
    // so a future production migration can link this profile without losing
    // ClearCoin progress.
    await FirebaseAuth.instance.signInAnonymously();
  } catch (e, st) {
    debugPrint('Firebase init/auth failed: $e\n$st');
  }
  runApp(const ClearBridgeBetaApp());
}

final _navigatorKey = GlobalKey<NavigatorState>();

class ClearBridgeBetaApp extends StatelessWidget {
  const ClearBridgeBetaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClearBridge Beta',
      navigatorKey: _navigatorKey,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: ClearBridgeColors.cyan),
      home: SplashScreen(
        onDiagnostics: () => _navigatorKey.currentState?.push(
          MaterialPageRoute(
            builder: (_) => CameraProbeScreen(
              getUserId: () => FirebaseAuth.instance.currentUser?.uid,
            ),
          ),
        ),
        onDone: () async {
          final prefs = await SharedPreferences.getInstance();
          final done = prefs.getBool('popia_completed') ?? false;
          if (done) {
            _goToCapture();
          } else {
            _navigatorKey.currentState?.pushReplacement(
              MaterialPageRoute(
                builder: (_) => UserDetailsPopiaScreen(onContinue: _goToCapture),
              ),
            );
          }
        },
      ),
    );
  }
}

void _goToCapture() {
  _navigatorKey.currentState?.pushReplacement(
    MaterialPageRoute(builder: (_) => const _CaptureRoute()),
  );
}

class _CaptureRoute extends StatelessWidget {
  const _CaptureRoute();

  @override
  Widget build(BuildContext context) {
    return FrontCaptureScreen(
      getUserId: () => FirebaseAuth.instance.currentUser?.uid,
      // No login screen in this single-flow app -- anonymous sign-in already
      // ran in main() before runApp(). This only fires if that sign-in
      // failed (see main.dart's try/catch), so retry it silently.
      onRequireLogin: () => FirebaseAuth.instance.signInAnonymously(),
      onComplete: (captureId) => _navigatorKey.currentState?.pushReplacement(
        MaterialPageRoute(
          builder: (_) => ClearCoinScreen(
            userId: FirebaseAuth.instance.currentUser?.uid ?? '',
            onContinue: () => _navigatorKey.currentState?.pushReplacement(
              MaterialPageRoute(
                builder: (_) => BetaThankYouScreen(onCaptureAgain: _goToCapture),
              ),
            ),
          ),
        ),
      ),
      onClose: () => SystemNavigator.pop(),
    );
  }
}
