import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mac_capture/mac_capture.dart';

import 'local_capture_uploader.dart';

void main() {
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

/// No login flow in the harness -- always "authenticated" as a fixed test
/// user ID, since MacCaptureScreen requires a non-null getUserId() to start.
const _testUserId = 'capture-harness-tester';

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
      uploader: const LocalCaptureUploader(),
      getUserId: () => _testUserId,
      onRequireLogin: () => Navigator.of(context).pop(),
      onComplete: (captureId) => _showResult(context, 'Saved locally: $captureId'),
      onQueued: (captureId) => _showResult(context, 'Queued offline: $captureId'),
      onClose: () => Navigator.of(context).pop(),
    );
  }

  void _showResult(BuildContext context, String message) {
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}
