import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ConnectivityService extends Notifier<bool> {
  StreamSubscription<List<ConnectivityResult>>? _sub;

  @override
  bool build() {
    _sub = Connectivity().onConnectivityChanged.listen((results) {
      state = results.any((r) => r != ConnectivityResult.none);
    });
    ref.onDispose(() => _sub?.cancel());
    return true; // optimistic start — avoids a false-offline flash at launch
  }
}

final connectivityServiceProvider = NotifierProvider<ConnectivityService, bool>(
  ConnectivityService.new,
);
