import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:mac_capture/mac_capture.dart';

/// Post-capture summary for the 8-phase oscillating mode.
///
/// Unlike [LastCaptureReviewScreen] this does NOT wait on an NFIQ-scored
/// backend result — no pipeline understands this capture's frame layout
/// yet (see OscillatingCaptureController's upload comment), so the doc is
/// written as 'captured_unprocessed' and this screen just reports what was
/// actually captured: frame counts per phase, so a session can be judged
/// sane before pulling frames from Storage by hand for closer inspection.
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
      body: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        future: FirebaseFirestore.instance.collection('captures').doc(captureId).get(),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator(color: CaptureColors.cyan));
          }
          final data = snapshot.data?.data();
          if (data == null) {
            return _ErrorView(message: 'Capture doc not found', onCaptureAgain: onCaptureAgain);
          }
          return _SummaryView(data: data, onCaptureAgain: onCaptureAgain);
        },
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onCaptureAgain});
  final String message;
  final VoidCallback onCaptureAgain;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: CaptureColors.error, size: 40),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: CaptureColors.silverBright)),
            const SizedBox(height: 24),
            ElevatedButton(onPressed: onCaptureAgain, child: const Text('Capture again')),
          ],
        ),
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

    // Per-phase frame counts, keyed by phaseNumber, from the flat frames[] list.
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
            _TotalsCard(total: total, burstTotal: burstTotal, transitionTotal: transitionTotal),
            const SizedBox(height: 20),
            Text(
              'PER-PHASE BREAKDOWN',
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
