import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:mac_capture/mac_capture.dart';

/// Result screen for the standalone sweep-burst test. Unlike
/// LastCaptureReviewScreen (capture_harness), this also surfaces the
/// sweep-specific diagnostic fields main.py already writes
/// (`nfiq2Score`/`afisSource`/`sweepBurstCandidates`) -- the whole point of
/// this app is judging whether sweep-burst material ever wins selection
/// when it isn't sharing a request budget with a main burst, so those
/// fields need to be visible here, not just the pass/fail summary a
/// consumer-facing screen would show.
class SweepResultScreen extends StatelessWidget {
  const SweepResultScreen({
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
        title: const Text('Sweep test result'),
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('captures')
            .doc(captureId)
            .snapshots(),
        builder: (context, snapshot) {
          final data = snapshot.data?.data();
          final status = data?['status'] as String?;

          if (data == null || status == null || status == 'pending' || status == 'enhancing') {
            return _ProcessingView(status: status, onCaptureAgain: onCaptureAgain);
          }
          if (status == 'failed') {
            return _ErrorView(
              message: data['error'] as String? ?? 'Processing failed',
              onCaptureAgain: onCaptureAgain,
            );
          }
          if (status != 'scored') {
            return _ProcessingView(status: status, onCaptureAgain: onCaptureAgain);
          }

          return _ResultView(data: data, onCaptureAgain: onCaptureAgain);
        },
      ),
    );
  }
}

class _ProcessingView extends StatelessWidget {
  const _ProcessingView({required this.status, required this.onCaptureAgain});
  final String? status;
  final VoidCallback onCaptureAgain;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: CaptureColors.cyan),
          const SizedBox(height: 16),
          Text(
            status == 'enhancing' ? 'Enhancing + scoring…' : 'Scoring capture…',
            style: const TextStyle(color: CaptureColors.silverBright, fontSize: 15),
          ),
          const SizedBox(height: 8),
          const Text(
            'This can take 2-3 minutes on the sweep-burst path.',
            style: TextStyle(color: CaptureColors.silverDim, fontSize: 12),
          ),
          const SizedBox(height: 24),
          TextButton(
            onPressed: onCaptureAgain,
            child: const Text('Skip — capture again'),
          ),
        ],
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
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: CaptureColors.silverBright),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: onCaptureAgain,
              child: const Text('Capture again'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultView extends StatelessWidget {
  const _ResultView({required this.data, required this.onCaptureAgain});

  final Map<String, dynamic> data;
  final VoidCallback onCaptureAgain;

  @override
  Widget build(BuildContext context) {
    final nfiqScore = (data['nfiqScore'] as num?)?.toDouble() ?? 0.0;
    final nfiqPass = data['nfiqPass'] as bool? ?? false;
    final nfiq2Score = (data['nfiq2Score'] as num?)?.toDouble();
    final afisSource = data['afisSource'] as String?;
    final enhancedPath = data['enhancedImagePath'] as String?;
    final sweepCandidates = data['sweepBurstCandidates'] as Map<String, dynamic>?;
    final statusColor = nfiqPass ? CaptureColors.success : CaptureColors.warning;

    // The real diagnostic this whole app exists to answer: did sweep-burst
    // material win selection at all, when it isn't sharing a request
    // budget with a main burst? afisSource carries names like 'left_amb',
    // 'sweepFusion', 'minutiae_core' etc. for sweep-origin winners (see
    // main.py's afis_params assembly) vs. 'native'/'freqNorm'/etc. for the
    // ordinary single-frame/fuse family.
    final sweepWon = afisSource != null &&
        (afisSource.startsWith('left') ||
            afisSource.startsWith('center') ||
            afisSource.startsWith('right') ||
            afisSource == 'sweepFusion' ||
            afisSource.startsWith('minutiae_'));

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            if (enhancedPath != null)
              _EnhancedImage(path: enhancedPath)
            else
              Container(
                height: 220,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: CaptureColors.cardBg,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'Enhanced image not available',
                  style: TextStyle(color: CaptureColors.silverDim),
                ),
              ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: BoxDecoration(
                color: statusColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: statusColor.withOpacity(0.4)),
              ),
              child: Column(
                children: [
                  Text(
                    nfiq2Score != null ? nfiq2Score.toStringAsFixed(0) : nfiqScore.toStringAsFixed(1),
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 40,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    nfiq2Score != null ? 'REAL NFIQ2' : 'PROXY NFIQ',
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: sweepWon
                    ? CaptureColors.success.withOpacity(0.12)
                    : CaptureColors.cardBg,
                borderRadius: BorderRadius.circular(10),
                border: sweepWon
                    ? Border.all(color: CaptureColors.success.withOpacity(0.4))
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    sweepWon ? 'SWEEP-BURST WON SELECTION' : 'sweep-burst did NOT win selection',
                    style: TextStyle(
                      color: sweepWon ? CaptureColors.success : CaptureColors.silverDim,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'afisSource: ${afisSource ?? '—'}',
                    style: const TextStyle(color: CaptureColors.silverBright, fontSize: 13),
                  ),
                  if (sweepCandidates != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'sweepBurstCandidates: ${sweepCandidates.length} field(s) recorded',
                      style: const TextStyle(color: CaptureColors.silverDim, fontSize: 11),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 28),
            ElevatedButton(
              onPressed: onCaptureAgain,
              child: const Text('Capture again'),
            ),
          ],
        ),
      ),
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
            height: 220,
            child: Center(child: CircularProgressIndicator(color: CaptureColors.cyan)),
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.network(
            snapshot.data!,
            errorBuilder: (_, __, ___) => Container(
              height: 220,
              alignment: Alignment.center,
              color: CaptureColors.cardBg,
              child: const Text(
                'Failed to load image',
                style: TextStyle(color: CaptureColors.silverDim),
              ),
            ),
          ),
        );
      },
    );
  }
}
