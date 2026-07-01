import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';
import '../../../core/theme/clearbridge_colors.dart';
import '../../../core/theme/clearbridge_typography.dart';
import '../../../core/constants/app_constants.dart';
import '../../auth/providers/auth_provider.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  VideoPlayerController? _videoController;
  bool _isMounted = false;
  bool _hasNavigated = false;
  Timer? _fallbackTimer;

  @override
  void initState() {
    super.initState();
    _isMounted = true;
    _initVideo();

    // Fallback timeout
    _fallbackTimer = Timer(const Duration(seconds: 5), () {
      _navigateToNextScreen();
    });
  }

  Future<void> _initVideo() async {
    final controller =
        VideoPlayerController.asset('assets/videos/splash_video.mp4');
    _videoController = controller;
    try {
      await controller.initialize();
      if (!_isMounted) return;
      controller.setLooping(false);
      controller.setVolume(1.0);
      controller.addListener(_videoListener);
      await controller.play();
      if (mounted) setState(() {});
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[ClearBridge] Splash video unavailable: $e');
      }
      // Asset missing → rely on fallback timer for redirect.
      _videoController = null;
      if (mounted) setState(() {});
    }
  }

  void _videoListener() {
    final c = _videoController;
    if (c == null) return;
    if (!c.value.isInitialized) return;
    if (c.value.hasError) {
      _navigateToNextScreen();
      return;
    }
    if (!c.value.isPlaying &&
        c.value.position >= c.value.duration &&
        c.value.duration > Duration.zero) {
      _navigateToNextScreen();
    }
  }

  @override
  void dispose() {
    _isMounted = false;
    _fallbackTimer?.cancel();
    final c = _videoController;
    if (c != null) {
      c.removeListener(_videoListener);
      c.dispose();
    }
    super.dispose();
  }

  void _navigateToNextScreen() {
    if (!_isMounted || _hasNavigated) return;
    if (kIsWeb) {
      final path = Uri.base.path;
      if (path.startsWith('/admin')) return;
    }
    _hasNavigated = true;
    final authState = ref.read(authProvider);
    final user = authState.valueOrNull;
    if (user == null) {
      context.go(AppConstants.loginRoute);
    } else {
      context.go(AppConstants.dashboardRoute);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _videoController;
    final isReady = c != null && c.value.isInitialized;

    return Scaffold(
      backgroundColor: Colors.black,
      // Tap anywhere to skip the splash (matches the new UI).
      body: GestureDetector(
        onTap: _navigateToNextScreen,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (isReady)
              Center(
                child: AspectRatio(
                  aspectRatio: c.value.aspectRatio,
                  child: VideoPlayer(c),
                ),
              )
            else
              Container(
                color: ClearBridgeColors.void_,
                child: Center(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final logoSize =
                          (constraints.maxWidth * 0.35).clamp(80.0, 140.0);
                      return Image.asset(
                        AppConstants.logoPath,
                        width: logoSize,
                        height: logoSize,
                        errorBuilder: (_, _, _) => Text(
                          'ClearBridge',
                          style: ClearBridgeTypography.heroText,
                        ),
                      );
                    },
                  ),
                ),
              ),
            // "Tap to skip" hint pill
            Positioned(
              bottom: 36,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  decoration: BoxDecoration(
                    color: ClearBridgeColors.void_.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(100),
                    border:
                        Border.all(color: Colors.white.withValues(alpha: 0.08)),
                  ),
                  child: Text(
                    'TAP TO SKIP',
                    style: ClearBridgeTypography.label.copyWith(
                      color: ClearBridgeColors.silver.withValues(alpha: 0.55),
                      letterSpacing: 0.08,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
