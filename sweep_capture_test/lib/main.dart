import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:mac_capture/mac_capture.dart';

import 'firebase_options.dart';
import 'sweep_capture_screen.dart';
import 'sweep_result_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Anonymous auth so Firestore/Storage security rules (which require
  // request.auth.uid == userId) are satisfied without a full login flow --
  // same pattern as capture_harness, same real project's rules.
  await FirebaseAuth.instance.signInAnonymously();
  runApp(const SweepCaptureTestApp());
}

final _navigatorKey = GlobalKey<NavigatorState>();
final _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

void _restart({String? message}) {
  _navigatorKey.currentState?.pushReplacement(
    MaterialPageRoute(builder: (_) => const _SweepCaptureRoute()),
  );
  if (message != null) {
    _scaffoldMessengerKey.currentState
        ?.showSnackBar(SnackBar(content: Text(message)));
  }
}

class SweepCaptureTestApp extends StatelessWidget {
  const SweepCaptureTestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sweep Burst Test',
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _scaffoldMessengerKey,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: const _SweepCaptureRoute(),
    );
  }
}

class _SweepCaptureRoute extends StatelessWidget {
  const _SweepCaptureRoute();

  @override
  Widget build(BuildContext context) {
    return SweepCaptureScreen(
      getUserId: () => FirebaseAuth.instance.currentUser?.uid,
      onRequireLogin: () => _restart(message: 'Auth expired — restarting'),
      onComplete: (captureId) => _navigatorKey.currentState?.pushReplacement(
        MaterialPageRoute(
          builder: (_) => SweepResultScreen(
            captureId: captureId,
            onCaptureAgain: _restart,
          ),
        ),
      ),
    );
  }
}
