import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'clearance_provider.dart';
import 'package:clearbridge/clearance_status_service.dart';

part 'countdown_timer_provider.g.dart';

@Riverpod(keepAlive: true)
Stream<Duration> countdownTimer(Ref ref) async* {
  final clearanceAsync = ref.watch(activeClearanceProvider);
  final clearance = clearanceAsync.valueOrNull;

  if (clearance == null ||
      clearance.status == 'completed' ||
      clearance.status == 'cleared' ||
      clearance.status == 'failed') {
    yield Duration.zero;
    return;
  }

  final deadline = clearance.expectedCompletionTime.toUtc();

  while (true) {
    final now = DateTime.now().toUtc();
    final remaining = deadline.difference(now);

    if (remaining.isNegative) {
      yield Duration.zero;
      break;
    }

    yield remaining;
    await Future.delayed(const Duration(seconds: 1));
  }
}

// Provider to get formatted time string: HH : MM : SS
@riverpod
String formattedCountdown(Ref ref) {
  final countdownAsync = ref.watch(countdownTimerProvider);
  final remaining = countdownAsync.valueOrNull ?? Duration.zero;

  if (remaining == Duration.zero) {
    return '00 : 00 : 00';
  }

  final hours = remaining.inHours;
  final minutes = remaining.inMinutes % 60;
  final seconds = remaining.inSeconds % 60;

  return '${hours.toString().padLeft(2, '0')} : ${minutes.toString().padLeft(2, '0')} : ${seconds.toString().padLeft(2, '0')}';
}

// Provider to get status update
@riverpod
ClearanceStatusUpdate clearanceStatus(Ref ref) {
  final clearanceAsync = ref.watch(activeClearanceProvider);
  final clearance = clearanceAsync.valueOrNull;
  final service = ref.watch(clearanceStatusServiceProvider);

  // We watch the timer provider to ensure this status update
  // recalculates every second and can flip to "delayed" status
  // without waiting for a Firestore change.
  ref.watch(countdownTimerProvider);

  if (clearance == null) {
    return ClearanceStatusUpdate(
      statusMessage: 'No active application',
      progressPercentage: 0,
    );
  }

  return service.getStatusUpdate(
    paidAt: clearance.paidAt.toUtc(),
    expectedCompletionTime: clearance.expectedCompletionTime.toUtc(),
    currentTime: DateTime.now().toUtc(),
    currentStatus: clearance.status,
  );
}
