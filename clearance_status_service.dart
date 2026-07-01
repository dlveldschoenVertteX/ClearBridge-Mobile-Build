import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'clearance_status_service.g.dart';

class ClearanceStatusUpdate {
  final String statusMessage;
  final double progressPercentage;

  ClearanceStatusUpdate({
    required this.statusMessage,
    required this.progressPercentage,
  });
}

@riverpod
ClearanceStatusService clearanceStatusService(ClearanceStatusServiceRef ref) {
  return ClearanceStatusService();
}

class ClearanceStatusService {
  /// Returns the status update based on the given timestamps (UTC) and current status.
  ClearanceStatusUpdate getStatusUpdate({
    required DateTime paidAt,
    required DateTime expectedCompletionTime,
    required DateTime currentTime,
    required String currentStatus,
  }) {
    // Ensure all inputs are UTC for consistent calculation
    final pAt = paidAt.toUtc();
    final eTime = expectedCompletionTime.toUtc();
    final cTime = currentTime.toUtc();

    final elapsed = cTime.difference(pAt);
    final totalDuration = eTime.difference(pAt);

    // 1. Calculate progress percentage (capped at 1.0)
    // Round to 1 decimal place to avoid unnecessary widget rebuilds
    // for sub-pixel progress changes
    double progress = totalDuration.inMilliseconds > 0
        ? elapsed.inMilliseconds / totalDuration.inMilliseconds
        : 0.0;
    progress = (progress.clamp(0.0, 1.0) * 1000).roundToDouble() / 1000;

    // 2. Check for failure status
    if (currentStatus.toLowerCase() == 'failed') {
      return ClearanceStatusUpdate(
        statusMessage: "Processing issue detected. Our team is investigating.",
        progressPercentage: progress,
      );
    }

    // 3. Check if explicitly completed
    final statusLower = currentStatus.toLowerCase();
    if (statusLower == 'completed' || statusLower == 'cleared') {
      return ClearanceStatusUpdate(
        statusMessage:
            "Your police clearance certificate is ready for download.",
        progressPercentage: 1.0,
      );
    }

    // 4. Handle expired but not completed state
    final isExpired = currentTime.isAfter(expectedCompletionTime);
    if (isExpired) {
      return ClearanceStatusUpdate(
        statusMessage: "Processing delayed. We'll notify you when ready.",
        progressPercentage: progress,
      );
    }

    // 5. Elapsed time rules
    String message;
    if (elapsed.inMinutes <= 5) {
      message = "Payment confirmed";
    } else if (elapsed.inMinutes <= 30) {
      message = "Submitted for verification";
    } else {
      message = "Processing with SAPS";
    }

    return ClearanceStatusUpdate(
      statusMessage: message,
      progressPercentage: progress,
    );
  }
}
