import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Provider to track whether the user is in the simplified "Fingerprint Only" flow
/// true: Simplified flow (no payment, skip selfie/ID if possible, return to dashboard)
/// false: Standard flow (selfie, ID, fingerprint, payment)
final isFingerprintOnlyProvider = StateProvider<bool>((ref) => false);
