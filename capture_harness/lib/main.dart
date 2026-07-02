import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mac_capture/mac_capture.dart';

import 'backend_capture_uploader.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Anonymous auth so Firestore/Storage security rules (which require
  // request.auth.uid == userId) are satisfied without a full login flow.
  await FirebaseAuth.instance.signInAnonymously();
  runApp(const ProviderScope(child: CaptureHarnessApp()));
}

class CaptureHarnessApp extends StatelessWidget {
  const CaptureHarnessApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MAC3D Capture Harness',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: const _HarnessHome(),
    );
  }
}

class _HarnessHome extends StatelessWidget {
  const _HarnessHome();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MAC3D Capture Harness')),
      body: Center(
        child: ElevatedButton.icon(
          icon: const Icon(Icons.fingerprint),
          label: const Text('Start capture'),
          onPressed: () => Navigator.of(context).push(
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
      onRequireLogin: () => Navigator.of(context).pop(),
      onComplete: (captureId) => _showResult(context, 'Uploaded: $captureId'),
      onQueued: (captureId) => _showResult(context, 'Queued offline: $captureId'),
      onClose: () => Navigator.of(context).pop(),
    );
  }

  void _showResult(BuildContext context, String message) {
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}
