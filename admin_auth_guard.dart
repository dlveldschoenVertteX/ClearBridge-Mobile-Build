import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/providers/auth_provider.dart';

class AdminAuthGuard {
  static const String adminClaimKey = 'admin';

  static Future<bool> isAdmin() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return false;
      final idTokenResult = await user.getIdTokenResult();
      final claims = idTokenResult.claims;
      if (claims == null) return false;
      return claims[adminClaimKey] == true;
    } catch (e) {
      debugPrint('Error checking admin status: $e');
      return false;
    }
  }
}

/// Cached admin claim — re-derived whenever the signed-in user changes.
/// Consumed by the router redirect so admin route protection is enforced
/// at the navigation layer, not just per-screen in initState().
final adminClaimProvider = FutureProvider<bool>((ref) async {
  final authState = ref.watch(authProvider);
  final user = authState.valueOrNull;
  if (user == null) return false;
  return AdminAuthGuard.isAdmin();
});
