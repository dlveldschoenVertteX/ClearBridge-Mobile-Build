import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/providers/user_profile_provider.dart';

/// ClearCoin reward constants + read-only balance access.
///
/// Rules (enforced server-side):
///   • Starts at 0; +[perSession] (+10) per completed MAC capture session.
///   • Capture sessions cap at [captureMax] (50) — 5 sessions.
///   • Referral bonus: +[referralMax] (10) when a referred user purchases.
///   • Overall cap: [totalMax] (60).
///   • 1 ClearCoin = R1 off a future police clearance.
///   • Purchasing a clearance resets the balance to 0.
///
/// SECURITY: the balance is mutated ONLY by Cloud Functions (Admin SDK).
/// Clients are blocked from writing `clearCoinBalance` / `referralCoinsClaimed`
/// by firestore.rules — there is no client-side award/reset path to exploit.
class ClearCoinService {
  ClearCoinService._();

  static const int captureMax = 50;
  static const int referralMax = 10;
  static const int totalMax = captureMax + referralMax; // 60

  // Legacy alias — retained so the server-side cap constant stays in sync.
  static const int maxBalance = captureMax; // 50

  static const int perSession = 10;
  static const int sessionsToMax = captureMax ~/ perSession; // 5
}

/// Current ClearCoin balance for the signed-in user (0–60), derived from the
/// live user-profile stream. Returns 0 when signed out or not yet earned.
final clearCoinBalanceProvider = Provider<int>((ref) {
  final profile = ref.watch(userProfileProvider).valueOrNull;
  final raw = profile?.clearCoinBalance ?? 0;
  return raw.clamp(0, ClearCoinService.totalMax);
});

/// Whether the +10 referral bonus has been awarded for this user.
final referralClaimedProvider = Provider<bool>((ref) {
  final profile = ref.watch(userProfileProvider).valueOrNull;
  return profile?.referralCoinsClaimed ?? false;
});
