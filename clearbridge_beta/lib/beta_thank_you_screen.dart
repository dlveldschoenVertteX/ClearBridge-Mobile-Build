import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:clearbridge_beta/clearbridge_colors.dart';

/// Final screen of the beta flow. Lets the tester either capture again or
/// exit the app entirely.
///
/// Also the one persistently-reachable screen (shown after every capture)
/// where the POPIA consent screen's "you can request permanent deletion at
/// any time" promise is actually actionable -- that screen itself is a
/// one-time gate the user never sees again after popia_completed is set, so
/// this is the only place in the app a returning user could exercise that
/// right. Writes to deletionRequests/{uid} (admin-reviewed, no auto-delete --
/// see firestore.rules) rather than deleting anything itself.
class BetaThankYouScreen extends StatelessWidget {
  const BetaThankYouScreen({super.key, required this.onCaptureAgain});

  final VoidCallback onCaptureAgain;

  Future<void> _requestDeletion(BuildContext context) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: ClearBridgeColors.cardBg,
        title: Text('Request Data Deletion',
            style: GoogleFonts.manrope(
                fontWeight: FontWeight.w800, color: ClearBridgeColors.silverBright)),
        content: Text(
          'This submits a request for ClearBridge to permanently delete your '
          'captured fingerprint data and account details. A team member will '
          'review and action it manually -- this is not instant.',
          style: GoogleFonts.manrope(color: ClearBridgeColors.silver, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Submit Request'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      await FirebaseFirestore.instance.collection('deletionRequests').doc(uid).set({
        'userId': uid,
        'status': 'pending',
        'requestedAt': FieldValue.serverTimestamp(),
        'source': 'clearbridge_beta',
      }, SetOptions(merge: true));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Deletion request submitted.')),
      );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not submit request. Please try again.'),
          backgroundColor: ClearBridgeColors.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ClearBridgeColors.void_,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
          child: Column(
            children: [
              const Spacer(flex: 3),
              Image.asset(
                'assets/images/app_logo.png',
                width: 96,
                height: 96,
                errorBuilder: (_, __, ___) => const Icon(
                  Icons.fingerprint,
                  size: 96,
                  color: ClearBridgeColors.cyan,
                ),
              ),
              const SizedBox(height: 36),
              Text(
                'Thank You',
                textAlign: TextAlign.center,
                style: GoogleFonts.manrope(
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  color: ClearBridgeColors.silverBright,
                  letterSpacing: -0.02,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Thank you for taking part in the ClearBridge beta.\n'
                'Your capture helps us build a faster, fairer way\n'
                'to get your police clearance.',
                textAlign: TextAlign.center,
                style: GoogleFonts.manrope(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: ClearBridgeColors.silver,
                  height: 1.6,
                ),
              ),
              const Spacer(flex: 4),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: onCaptureAgain,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ClearBridgeColors.cyan,
                    foregroundColor: ClearBridgeColors.void_,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    elevation: 0,
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                  label: Text('Capture Again',
                      style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w800)),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: () => SystemNavigator.pop(),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: ClearBridgeColors.silverBright,
                    side: BorderSide(color: ClearBridgeColors.silverBright.withValues(alpha: 0.24)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  icon: const Icon(Icons.logout_rounded, size: 20),
                  label: Text('Exit',
                      style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w800)),
                ),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => _requestDeletion(context),
                child: Text(
                  'Request my data be deleted',
                  style: GoogleFonts.manrope(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: ClearBridgeColors.silverDim,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
