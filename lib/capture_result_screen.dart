import 'dart:async';
import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';

import 'package:clearbridge/app_constants.dart';
import 'package:clearbridge/clearbridge_colors.dart';
import 'package:clearbridge/capture_angles.dart';

class CaptureResultScreen extends StatefulWidget {
  const CaptureResultScreen({
    super.key,
    required this.captureId,
    this.isQueued = false,
  });

  final String captureId;
  final bool isQueued;

  @override
  State<CaptureResultScreen> createState() => _CaptureResultScreenState();
}

class _CaptureResultScreenState extends State<CaptureResultScreen> {
  bool _timedOut = false;
  Timer? _watchdog;

  static const _processingStatuses = {
    'pending',
    'uploading',
    'enhancing',
  };

  void _startWatchdog() {
    _watchdog ??= Timer(const Duration(seconds: 180), () {
      if (mounted) setState(() => _timedOut = true);
    });
  }

  void _cancelWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_timedOut) {
      return Scaffold(
        backgroundColor: ClearBridgeColors.void_,
        body: SafeArea(
          child: _ErrorBody(
            message: 'Enhancement took too long. Please check your connection and try again.',
            onRetake: () => context.go(AppConstants.continuousCaptureRoute),
          ),
        ),
      );
    }

    if (widget.isQueued) {
      return Scaffold(
        backgroundColor: ClearBridgeColors.void_,
        body: SafeArea(
          child: _QueuedBody(
            onDone: () => context.go(AppConstants.dashboardRoute),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: ClearBridgeColors.void_,
      body: SafeArea(
        child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('captures')
              .doc(widget.captureId)
              .snapshots(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              _cancelWatchdog();
              return _ErrorBody(
                message: snapshot.error.toString(),
                onRetake: () =>
                    context.go(AppConstants.continuousCaptureRoute),
              );
            }

            final data = snapshot.data?.data();
            final status = data?['status'] as String? ?? 'pending';

            if (!snapshot.hasData ||
                data == null ||
                _processingStatuses.contains(status)) {
              _startWatchdog();
              return _ProcessingBody(status: status);
            }

            _cancelWatchdog();

            if (status == 'scored') {
              final nfiqScore =
                  (data['nfiqScore'] as num?)?.toDouble() ?? 0;
              final nfiqPass = data['nfiqPass'] as bool? ?? false;
              final henryClass = data['henryClass'] as String? ?? '—';
              final sfmCoverage =
                  (data['sfmCoverage'] as num?)?.toDouble() ?? 0.0;
              final pipelineVersion =
                  data['pipelineVersion'] as String? ?? '';

              if (nfiqPass) {
                return _PassBody(
                  nfiqScore: nfiqScore,
                  henryClass: henryClass,
                  sfmCoverage: sfmCoverage,
                  pipelineVersion: pipelineVersion,
                  onContinue: () => context.go(AppConstants.clearCoinRewardRoute),
                );
              }
              return _FailBody(
                nfiqScore: nfiqScore,
                henryClass: henryClass,
                sfmCoverage: sfmCoverage,
                onRetake: () => context.go(AppConstants.continuousCaptureRoute),
              );
            }

            if (status == 'failed') {
              final reason =
                  data['failureReason'] as String? ?? 'Unknown error';
              return _ErrorBody(
                message: reason,
                onRetake: () =>
                    context.go(AppConstants.continuousCaptureRoute),
              );
            }

            return _ProcessingBody(status: status);
          },
        ),
      ),
    );
  }
}

// ── Shared header ─────────────────────────────────────────────────────────────

class _ReportHeader extends StatelessWidget {
  const _ReportHeader();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 8),
        Image.asset(
          'assets/images/app_logo.png',
          height: 44,
          fit: BoxFit.contain,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: Container(height: 1, color: ClearBridgeColors.cyanBorder),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                'BIOMETRIC REPORT',
                style: TextStyle(
                  color: ClearBridgeColors.cyan.withValues(alpha: 0.70),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2.5,
                ),
              ),
            ),
            Expanded(
              child: Container(height: 1, color: ClearBridgeColors.cyanBorder),
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

// ── Score arc ─────────────────────────────────────────────────────────────────

class _ScoreArc extends StatelessWidget {
  const _ScoreArc({
    required this.score,
    required this.arcColor,
    required this.label,
    required this.labelColor,
  });

  final double score;
  final Color arcColor;
  final String label;
  final Color labelColor;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 148,
        height: 148,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _GaugeArcPainter(score: score, arcColor: arcColor),
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  score.toStringAsFixed(0),
                  style: TextStyle(
                    color: arcColor,
                    fontSize: 36,
                    fontWeight: FontWeight.w900,
                    height: 1.0,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '/ 100',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: arcColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      color: labelColor,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _GaugeArcPainter extends CustomPainter {
  const _GaugeArcPainter({required this.score, required this.arcColor});

  final double score;
  final Color arcColor;

  // 270° gauge: starts at 7:30 o'clock, ends at 4:30 o'clock.
  // Flutter canvas angles are clockwise from the 3 o'clock position.
  // 135° from 3 o'clock = 7:30 position (bottom-left).
  static const double _start  = 135.0 * math.pi / 180.0;
  static const double _total  = 270.0 * math.pi / 180.0;
  static const double _stroke = 10.0;

  @override
  void paint(Canvas canvas, Size size) {
    final r    = (math.min(size.width, size.height) - _stroke) / 2;
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: r,
    );
    final paint = Paint()
      ..style       = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap   = StrokeCap.round;

    canvas.drawArc(rect, _start, _total, false,
        paint..color = Colors.white.withValues(alpha: 0.07));

    final fill = _total * (score / 100).clamp(0.0, 1.0);
    if (fill > 0) {
      canvas.drawArc(rect, _start, fill, false, paint..color = arcColor);
    }
  }

  @override
  bool shouldRepaint(_GaugeArcPainter old) =>
      old.score != score || old.arcColor != arcColor;
}

// ── Analysis card ─────────────────────────────────────────────────────────────

class _AnalysisCard extends StatelessWidget {
  const _AnalysisCard({
    required this.henryClass,
    required this.sfmCoverage,
    this.pipelineVersion = '',
    this.accentColor = Colors.white,
  });

  final String henryClass;
  final double sfmCoverage;
  final String pipelineVersion;
  final Color accentColor;

  String _henryLabel(String code) => switch (code) {
        'RL' => 'Right Loop',
        'LL' => 'Left Loop',
        'W' => 'Whorl',
        'A' => 'Arch',
        'TA' => 'Tented Arch',
        _ => code,
      };

  @override
  Widget build(BuildContext context) {
    final coveragePct = (sfmCoverage * 100).round();
    final coverageColor = sfmCoverage >= 0.70
        ? ClearBridgeColors.success
        : sfmCoverage >= 0.45
            ? ClearBridgeColors.warning
            : ClearBridgeColors.error;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        color: ClearBridgeColors.steel,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: ClearBridgeColors.cardBorder),
      ),
      child: Column(
        children: [
          _Row(
            label: 'Pattern Type',
            value: _henryLabel(henryClass),
            valueColor: Colors.white,
          ),
          _divider(),
          _Row(
            label: '3D Coverage',
            value: '$coveragePct%',
            valueColor: coverageColor,
            trailing: _CoverageBar(coverage: sfmCoverage, color: coverageColor),
          ),
          if (pipelineVersion.isNotEmpty) ...[
            _divider(),
            _Row(
              label: 'Analysis Engine',
              value: pipelineVersion.replaceFirst(RegExp(r'^lighting-'), 'MACALYZE-'),
              valueColor: Colors.white.withValues(alpha: 0.35),
            ),
          ],
        ],
      ),
    );
  }

  Widget _divider() => const Divider(
        color: ClearBridgeColors.cardBorder,
        height: 22,
      );
}

class _CoverageBar extends StatelessWidget {
  const _CoverageBar({required this.coverage, required this.color});

  final double coverage;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 56,
      height: 6,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(
          value: coverage.clamp(0.0, 1.0),
          backgroundColor: Colors.white.withValues(alpha: 0.10),
          valueColor: AlwaysStoppedAnimation<Color>(color),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.value,
    this.valueColor,
    this.trailing,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.55),
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (trailing != null) ...[trailing!, const SizedBox(width: 10)],
            Text(
              value,
              style: TextStyle(
                color: valueColor ?? Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ── State bodies ──────────────────────────────────────────────────────────────

class _ProcessingBody extends StatelessWidget {
  const _ProcessingBody({required this.status});

  final String status;

  String get _label => switch (status) {
        'pending' => 'Preparing...',
        'uploading' => 'Uploading frames...',
        'enhancing' => 'Enhancing fingerprint...',
        'stitching' => 'Stitching angles...',
        'scoring' => 'Scoring quality...',
        _ => 'Processing...',
      };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          const _ReportHeader(),
          const Spacer(),
          const SizedBox(
            width: 64,
            height: 64,
            child: CircularProgressIndicator(
              strokeWidth: 4,
              color: ClearBridgeColors.cyan,
            ),
          ),
          const SizedBox(height: 28),
          Text(
            _label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Analysing your fingerprint capture.\nThis usually takes a few seconds.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 14,
              height: 1.55,
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

class _PassBody extends StatefulWidget {
  const _PassBody({
    required this.nfiqScore,
    required this.henryClass,
    required this.sfmCoverage,
    required this.pipelineVersion,
    required this.onContinue,
  });

  final double nfiqScore;
  final String henryClass;
  final double sfmCoverage;
  final String pipelineVersion;
  final VoidCallback onContinue;

  @override
  State<_PassBody> createState() => _PassBodyState();
}

class _PassBodyState extends State<_PassBody> {
  final AudioPlayer _player = AudioPlayer();

  @override
  void initState() {
    super.initState();
    _playChime();
  }

  Future<void> _playChime() async {
    try {
      await _player.setAsset('assets/audio/capture_success.wav');
      unawaited(_player.play());
    } catch (_) {}
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isGold = widget.nfiqScore >= nfiqGold;
    final arcColor =
        isGold ? ClearBridgeColors.gold : ClearBridgeColors.success;
    final tierLabel = isGold ? 'GOLD' : 'PASS';
    final tierLabelColor =
        isGold ? ClearBridgeColors.goldLight : ClearBridgeColors.success;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _ReportHeader(),

          // Status
          Text(
            'CLEARED',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: arcColor,
              fontSize: 28,
              fontWeight: FontWeight.w900,
              letterSpacing: 5,
            ),
          ),
          if (isGold) ...[
            const SizedBox(height: 8),
            Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                decoration: BoxDecoration(
                  gradient: ClearBridgeColors.gradGold,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  'GOLD QUALITY',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
              ),
            ),
          ],

          const SizedBox(height: 28),

          // Score arc
          _ScoreArc(
            score: widget.nfiqScore,
            arcColor: arcColor,
            label: tierLabel,
            labelColor: tierLabelColor,
          ),

          const SizedBox(height: 28),

          // Analysis card
          _AnalysisCard(
            henryClass: widget.henryClass,
            sfmCoverage: widget.sfmCoverage,
            pipelineVersion: widget.pipelineVersion,
            accentColor: arcColor,
          ),

          // Low-coverage tip
          if (widget.sfmCoverage > 0 && widget.sfmCoverage < 0.70) ...[
            const SizedBox(height: 14),
            const _TipBanner(
              icon: Icons.rotate_right_rounded,
              text: 'Tip: A slower, steadier orbit improves 3D coverage on your next capture.',
              color: ClearBridgeColors.cyan,
            ),
          ],

          const SizedBox(height: 28),

          SizedBox(
            height: 52,
            child: ElevatedButton(
              onPressed: widget.onContinue,
              style: ElevatedButton.styleFrom(
                backgroundColor: arcColor,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
              child: const Text(
                'Continue',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
          ),

          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _FailBody extends StatelessWidget {
  const _FailBody({
    required this.nfiqScore,
    required this.henryClass,
    required this.sfmCoverage,
    required this.onRetake,
  });

  final double nfiqScore;
  final String henryClass;
  final double sfmCoverage;
  final VoidCallback onRetake;

  @override
  Widget build(BuildContext context) {
    const arcColor = ClearBridgeColors.warning;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _ReportHeader(),

          const Text(
            'RETRY',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: ClearBridgeColors.warning,
              fontSize: 28,
              fontWeight: FontWeight.w900,
              letterSpacing: 5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Quality below minimum threshold',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),

          const SizedBox(height: 28),

          _ScoreArc(
            score: nfiqScore,
            arcColor: arcColor,
            label: 'LOW',
            labelColor: arcColor,
          ),

          const SizedBox(height: 28),

          _AnalysisCard(
            henryClass: henryClass,
            sfmCoverage: sfmCoverage,
            accentColor: arcColor,
          ),

          const SizedBox(height: 14),

          const _TipBanner(
            icon: Icons.wb_sunny_outlined,
            text: 'For best results: use natural or bright indoor light, hold steady, and keep your thumb flat against the lens.',
            color: ClearBridgeColors.warning,
          ),

          const SizedBox(height: 28),

          SizedBox(
            height: 52,
            child: ElevatedButton(
              onPressed: onRetake,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
              child: const Text(
                'Retake',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
          ),

          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

// ── Tip banner ────────────────────────────────────────────────────────────────

class _TipBanner extends StatelessWidget {
  const _TipBanner({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.72),
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Error / Queued ────────────────────────────────────────────────────────────

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.message, required this.onRetake});

  final String message;
  final VoidCallback onRetake;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _ReportHeader(),
          const Spacer(),
          const Icon(
            Icons.cloud_off_outlined,
            color: ClearBridgeColors.error,
            size: 64,
          ),
          const SizedBox(height: 20),
          const Text(
            'Processing Failed',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 13,
              height: 1.5,
            ),
          ),
          const Spacer(),
          SizedBox(
            height: 52,
            child: ElevatedButton(
              onPressed: onRetake,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
              child: const Text(
                'Try Again',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QueuedBody extends StatelessWidget {
  const _QueuedBody({required this.onDone});

  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _ReportHeader(),
          const Spacer(),
          const Icon(
            Icons.cloud_upload_outlined,
            color: ClearBridgeColors.cyan,
            size: 64,
          ),
          const SizedBox(height: 20),
          const Text(
            'Saved',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Your capture is saved on this device and will upload automatically when you\'re back online.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.65),
              fontSize: 14,
              height: 1.55,
            ),
          ),
          const Spacer(),
          SizedBox(
            height: 52,
            child: ElevatedButton(
              onPressed: onDone,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
              child: const Text(
                'Done',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
