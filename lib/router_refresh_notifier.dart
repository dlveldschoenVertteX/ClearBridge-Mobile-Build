import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:clearbridge/auth_provider.dart';
import 'package:clearbridge/user_profile_provider.dart'
    show captureConsentProvider, userProfileCompletedProvider;
import 'package:clearbridge/admin_auth_guard.dart';

part 'router_refresh_notifier.g.dart';

@riverpod
Listenable routerRefreshNotifier(Ref ref) {
  final notifier = ChangeNotifier();

  ref.listen(authProvider, (previous, next) {
    if (previous?.valueOrNull?.uid != next.valueOrNull?.uid) {
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      notifier.notifyListeners();
    }
  });

  ref.listen(userProfileCompletedProvider, (previous, next) {
    if (previous?.valueOrNull != next.valueOrNull) {
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      notifier.notifyListeners();
    }
  });

  ref.listen(adminClaimProvider, (previous, next) {
    if (previous?.valueOrNull != next.valueOrNull) {
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      notifier.notifyListeners();
    }
  });

  ref.listen(captureConsentProvider, (previous, next) {
    if (previous?.valueOrNull != next.valueOrNull) {
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      notifier.notifyListeners();
    }
  });

  return notifier;
}
