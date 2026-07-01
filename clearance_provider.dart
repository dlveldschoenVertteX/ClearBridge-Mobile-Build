import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../auth/providers/auth_provider.dart';
import '../models/clearance_model.dart';
import '../repository/clearance_repository.dart';

part 'clearance_provider.g.dart';

@Riverpod(keepAlive: true)
class SelectedClearanceId extends _$SelectedClearanceId {
  @override
  String? build() {
    ref.listen<AsyncValue<List<ClearanceModel>>>(userClearancesProvider, (
      _,
      next,
    ) {
      final selectedId = state;
      if (selectedId == null) return;

      next.whenData((clearances) {
        final isKnownSelection = clearances.any(
          (clearance) => clearance.clearanceId == selectedId,
        );

        if (isKnownSelection) return;

        final fallbackId = clearances.isNotEmpty
            ? clearances.first.clearanceId
            : null;

        if (state != fallbackId) {
          state = fallbackId;
        }
      });
    });

    ref.listen(authProvider, (_, next) {
      if (next.valueOrNull == null && state != null) {
        state = null;
      }
    });

    return null;
  }

  void set(String? id) => state = id;
}

@riverpod
Stream<ClearanceModel?> latestClearance(Ref ref) {
  final authState = ref.watch(authProvider);
  final user = authState.valueOrNull;

  if (user == null) {
    return Stream.value(null);
  }

  return ref.watch(clearanceRepositoryProvider).streamLatestClearance(user.uid);
}

@riverpod
AsyncValue<ClearanceModel?> activeClearance(Ref ref) {
  final selectedId = ref.watch(selectedClearanceIdProvider);

  if (selectedId != null) {
    // Try to find the selected clearance in the already loaded list
    final listAsync = ref.watch(userClearancesProvider);

    return listAsync.whenData((list) {
      if (list.isEmpty) return null;
      try {
        return list.firstWhere((c) => c.clearanceId == selectedId);
      } catch (_) {
        return list.firstOrNull;
      }
    });
  }

  // Default to latest
  return ref.watch(latestClearanceProvider);
}

@riverpod
Stream<List<ClearanceModel>> userClearances(Ref ref) {
  final authState = ref.watch(authProvider);
  final user = authState.valueOrNull;

  if (user == null) {
    return Stream.value([]);
  }

  return ref.watch(clearanceRepositoryProvider).streamUserClearances(user.uid);
}
