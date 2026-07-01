import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../constants/app_constants.dart';
import 'router_service.dart';

part 'deep_link_service.g.dart';

@riverpod
DeepLinkService deepLinkService(Ref ref) {
  final router = ref.watch(routerProvider);
  final service = DeepLinkService(router);
  ref.onDispose(service.dispose);
  return service;
}

class DeepLinkService {
  DeepLinkService(this._router) {
    _init();
  }

  final GoRouter _router;
  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _sub;

  Future<void> _init() async {
    // iOS cold-start: GoRouter does not intercept Universal Links — app_links
    // captures the initial URI here and routes it. Android cold-start is handled
    // by GoRouter via the intent, so we skip it to avoid double-navigation.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        final initialUri = await _appLinks.getInitialLink();
        if (initialUri != null) _handleUri(initialUri);
      } catch (e) {
        debugPrint('[DeepLink] initial link error: $e');
      }
    }

    // Hot-start (app already running): fires for both Android and iOS.
    _sub = _appLinks.uriLinkStream.listen(
      _handleUri,
      onError: (e) => debugPrint('[DeepLink] stream error: $e'),
    );
  }

  void _handleUri(Uri uri) {
    final path = uri.path;
    final params = uri.queryParameters;

    // Firebase Auth email action links:
    //   https://clearbridge-dc699.web.app/__/auth/action?mode=X&oobCode=Y
    //   https://clearbridge-dc699.firebaseapp.com/__/auth/action?mode=X&oobCode=Y
    if (path == '/__/auth/action') {
      final mode = params['mode'];
      final oobCode = params['oobCode'];
      if (mode != null && oobCode != null) {
        _router.go(Uri(
          path: AppConstants.emailActionRoute,
          queryParameters: {'mode': mode, 'oobCode': oobCode},
        ).toString());
        return;
      }
    }

    // Custom URL scheme fallback: clearbridge://auth/action?mode=X&oobCode=Y
    if (uri.scheme == 'clearbridge' &&
        (uri.host == 'auth' || uri.path == '/auth/action')) {
      final mode = params['mode'];
      final oobCode = params['oobCode'];
      if (mode != null && oobCode != null) {
        _router.go(Uri(
          path: AppConstants.emailActionRoute,
          queryParameters: {'mode': mode, 'oobCode': oobCode},
        ).toString());
        return;
      }
    }

    // Referral / invite links: https://clearbridge-dc699.web.app/invite?code=X
    if (path == '/invite' || path == '/ref') {
      final code = params['code'] ?? params['ref'];
      if (code != null) {
        _router.go('${AppConstants.loginRoute}?ref=$code');
        return;
      }
    }

    debugPrint('[DeepLink] unhandled URI: $uri');
  }

  void dispose() {
    _sub?.cancel();
  }
}
