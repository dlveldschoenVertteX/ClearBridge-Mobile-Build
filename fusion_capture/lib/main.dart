import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:mac_capture/mac_capture.dart';

import 'firebase_options.dart';
import 'fusion_capture_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  // Anonymous auth up front: the Firestore rules key every capture write off
  // request.auth.uid, so a session with no user can never write a doc.
  if (FirebaseAuth.instance.currentUser == null) {
    try {
      await FirebaseAuth.instance.signInAnonymously();
    } catch (_) {
      // Non-fatal here -- the controller retries at upload time and surfaces
      // a real error there rather than blocking app start.
    }
  }
  runApp(const FusionCaptureApp());
}

class FusionCaptureApp extends StatelessWidget {
  const FusionCaptureApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fusion Capture',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: CaptureColors.void_,
        colorScheme: ColorScheme.fromSeed(
          seedColor: CaptureColors.gold,
          brightness: Brightness.dark,
        ),
      ),
      home: const FusionCaptureScreen(),
    );
  }
}
