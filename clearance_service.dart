import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'clearance_service.g.dart';

@riverpod
ClearanceService clearanceService(Ref ref) {
  return ClearanceService();
}

class ClearanceService {
  /// Calculates the application deadline based on the selected tier.
  /// Priority: 2 hours
  /// Standard: 4 hours
  DateTime calculateDeadline(String? tier, DateTime startTime) {
    final normalizedTier = tier?.toLowerCase() ?? 'standard';
    final deadlineHours = normalizedTier == 'priority' ? 2 : 4;
    return startTime.add(Duration(hours: deadlineHours));
  }

  /// Returns the price for a specific tier.
  /// This centralizes pricing logic in one place.
  double getTierPrice(String tier) {
    final normalizedTier = tier.toLowerCase();
    if (normalizedTier == 'priority') {
      return 499.0;
    }
    return 350.0;
  }
}
