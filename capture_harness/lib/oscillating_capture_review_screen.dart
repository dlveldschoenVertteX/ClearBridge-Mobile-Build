import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:mac_capture/mac_capture.dart';

/// Post-capture summary for the 8-phase oscillating mode.
///
/// Streams the same `captures/{id}` doc `processEnhanceAndScore` writes to
/// for every other capture mode — this mode now triggers that pipeline too
/// (see OscillatingCaptureController's upload comment), so this screen
/// shows the live processing status and, once scored, the NFIQ result and
/// enhanced print exactly like [LastCaptureReviewScreen]. Below that it
/// also shows the frame-count breakdown per phase — useful context specific
/// to this experimental mode (e.g. how many of the ~400 captured frames the
/// backend's angle-binning actually kept) that the other modes don't need.
class OscillatingCaptureReviewScreen extends StatelessWidget {
  const OscillatingCaptureReviewScreen({
    super.key,
    required this.captureId,
    required this.onCaptureAgain,
  });

  final String captureId;
  final VoidCallback onCaptureAgain;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CaptureColors.void_,
      appBar: AppBar(
        backgroundColor: CaptureColors.void_,
        elevation: 0,
        title: const Text('Capture summary'),
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance.collection('captures').doc(captureId).snapshots(),
        builder: (context, snapshot) {
          final data = snapshot.data?.data();
          if (data == null) {
            return const Center(child: CircularProgressIndicator(color: CaptureColors.cyan));
          }
          return _SummaryView(data: data, onCaptureAgain: onCaptureAgain);
        },
      ),
    );
  }
}

class _SummaryView extends StatelessWidget {
  const _SummaryView({required this.data, required this.onCaptureAgain});
  final Map<String, dynamic> data;
  final VoidCallback onCaptureAgain;

  @override
  Widget build(BuildContext context) {
    final total = (data['frameCount'] as num?)?.toInt() ?? 0;
    final burstTotal = (data['burstFrameCount'] as num?)?.toInt() ?? 0;
    final transitionTotal = (data['transitionFrameCount'] as num?)?.toInt() ?? 0;
    final phases = (data['phases'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    final frames = (data['frames'] as List?)?.cast<Map<String, dynamic>>() ?? const [];

    final countsByPhase = <int, int>{};
    for (final f in frames) {
      final n = (f['phaseNumber'] as num?)?.toInt();
      if (n != null) countsByPhase[n] = (countsByPhase[n] ?? 0) + 1;
    }

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ProcessingStatusCard(data: data, onCaptureAgain: onCaptureAgain),
            const SizedBox(height: 20),
            _TotalsCard(total: total, burstTotal: burstTotal, transitionTotal: transitionTotal),
            const SizedBox(height: 20),
            Text(
              'PER-PHASE BREAKDOWN (captured)',
              style: CaptureTypography.label.copyWith(fontSize: 11, letterSpacing: 1.2),
            ),
            const SizedBox(height: 10),
            for (var i = 0; i < phases.length; i++)
              _PhaseRow(
                phaseNumber: i + 1,
                label: (phases[i]['label'] as String?) ?? '—',
                type: (phases[i]['type'] as String?) ?? '—',
                frameCount: countsByPhase[i + 1] ?? 0,
              ),
            const SizedBox(height: 28),
            ElevatedButton(onPressed: onCaptureAgain, child: const Text('Capture again')),
          ],
        ),
      ),
    );
  }
}

/// Live SfM/NFIQ processing status — pending/enhancing shows a spinner,
/// failed shows the backend's error, scored shows the result plus the
/// binning stats _download_oscillating_frames wrote (oscBinsUsed etc.).
class _ProcessingStatusCard extends StatelessWidget {
  const _ProcessingStatusCard({required this.data, required this.onCaptureAgain});
  final Map<String, dynamic> data;
  final VoidCallback onCaptureAgain;

  @override
  Widget build(BuildContext context) {
    final status = data['status'] as String?;

    if (status == 'failed') {
      final reason = (data['failureReason'] ?? data['sfmError'] ?? 'Processing failed') as String;
      return _card(
        child: Column(
          children: [
            const Icon(Icons.error_outline, color: CaptureColors.error, size: 32),
            const SizedBox(height: 10),
            Text(
              reason,
              textAlign: TextAlign.center,
              style: CaptureTypography.body.copyWith(fontSize: 13, color: CaptureColors.silverBright),
            ),
          ],
        ),
      );
    }

    if (status != 'scored') {
      return _card(
        child: Column(
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: CaptureColors.cyan),
            ),
            const SizedBox(height: 10),
            Text(
              status == 'enhancing' ? 'Reconstructing (SfM + enhancement)…' : 'Waiting for processing to start…',
              style: CaptureTypography.label.copyWith(fontSize: 12, color: CaptureColors.silverBright),
            ),
          ],
        ),
      );
    }

    final nfiqScore = (data['nfiqScore'] as num?)?.toDouble() ?? 0.0;
    final nfiqPass = data['nfiqPass'] as bool? ?? false;
    final henryClass = data['henryClass'] as String? ?? '—';
    final sfmCoverage = (data['sfmCoverage'] as num?)?.toDouble();
    final oscBinsUsed = (data['oscBinsUsed'] as num?)?.toInt();
    final enhancedPath = data['enhancedImagePath'] as String?;
    final statusColor = nfiqPass ? CaptureColors.success : CaptureColors.warning;

    return _card(
      child: Column(
        children: [
          if (enhancedPath != null) ...[
            _EnhancedImage(path: enhancedPath),
            const SizedBox(height: 16),
          ],
          Text(
            nfiqScore.toStringAsFixed(1),
            style: TextStyle(color: statusColor, fontSize: 34, fontWeight: FontWeight.w800),
          ),
          Text(
            nfiqPass ? 'NFIQ PASS' : 'NFIQ BELOW THRESHOLD',
            style: TextStyle(color: statusColor, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.5),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            alignment: WrapAlignment.center,
            children: [
              Text('Henry: $henryClass', style: CaptureTypography.label.copyWith(fontSize: 11)),
              if (sfmCoverage != null)
                Text('SfM coverage: ${(sfmCoverage * 100).round()}%',
                    style: CaptureTypography.label.copyWith(fontSize: 11)),
              if (oscBinsUsed != null)
                Text('Angle bins used: $oscBinsUsed', style: CaptureTypography.label.copyWith(fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        color: CaptureColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: CaptureColors.cardBorder),
      ),
      child: child,
    );
  }
}

class _EnhancedImage extends StatelessWidget {
  const _EnhancedImage({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: FirebaseStorage.instance.ref(path).getDownloadURL(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox(
            height: 160,
            child: Center(child: CircularProgressIndicator(color: CaptureColors.cyan)),
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.network(
            snapshot.data!,
            errorBuilder: (_, __, ___) => Container(
              height: 160,
              alignment: Alignment.center,
              color: CaptureColors.void_,
              child: const Text('Failed to load image', style: TextStyle(color: CaptureColors.silverDim)),
            ),
          ),
        );
      },
    );
  }
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.total, required this.burstTotal, required this.transitionTotal});
  final int total;
  final int burstTotal;
  final int transitionTotal;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        color: CaptureColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: CaptureColors.cardBorder),
      ),
      child: Column(
        children: [
          Text(
            '$total',
            style: const TextStyle(
              color: CaptureColors.cyan,
              fontSize: 40,
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(
            'FRAMES CAPTURED',
            style: CaptureTypography.label.copyWith(fontSize: 12, letterSpacing: 1.0),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _Stat(label: 'Burst', value: burstTotal),
              _Stat(label: 'Transition', value: transitionTotal),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text('$value', style: const TextStyle(color: CaptureColors.silverBright, fontSize: 20, fontWeight: FontWeight.w700)),
        Text(label, style: CaptureTypography.label.copyWith(fontSize: 10)),
      ],
    );
  }
}

class _PhaseRow extends StatelessWidget {
  const _PhaseRow({
    required this.phaseNumber,
    required this.label,
    required this.type,
    required this.frameCount,
  });
  final int phaseNumber;
  final String label;
  final String type;
  final int frameCount;

  @override
  Widget build(BuildContext context) {
    final isBurst = type == 'burst';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: CaptureColors.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: CaptureColors.cardBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: (isBurst ? CaptureColors.cyan : CaptureColors.gold).withValues(alpha: 0.18),
            ),
            child: Text(
              '$phaseNumber',
              style: TextStyle(
                color: isBurst ? CaptureColors.cyan : CaptureColors.gold,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '$label · ${isBurst ? 'burst' : 'transition'}',
              style: CaptureTypography.body.copyWith(fontSize: 13, color: CaptureColors.silverBright),
            ),
          ),
          Text(
            '$frameCount frames',
            style: CaptureTypography.label.copyWith(fontSize: 11),
          ),
        ],
      ),
    );
  }
}
