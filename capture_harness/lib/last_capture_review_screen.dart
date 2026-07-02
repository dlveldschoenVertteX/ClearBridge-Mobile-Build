import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:mac_capture/mac_capture.dart';

/// Shows the pipeline's result for a just-uploaded capture: NFIQ score,
/// pass/fail, and the actual NNS-enhanced flat print image once the backend
/// finishes scoring. Closes the feedback loop for beta testing -- without
/// this, judging capture quality means manually pulling Firestore/Storage
/// after the fact.
class LastCaptureReviewScreen extends StatelessWidget {
  const LastCaptureReviewScreen({
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
        title: const Text('Capture result'),
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('captures')
            .doc(captureId)
            .snapshots(),
        builder: (context, snapshot) {
          final data = snapshot.data?.data();
          final status = data?['status'] as String?;

          if (data == null || status == null || status == 'pending') {
            return _ProcessingView(onCaptureAgain: onCaptureAgain);
          }
          if (status == 'failed') {
            return _ErrorView(
              message: data['error'] as String? ?? 'Processing failed',
              onCaptureAgain: onCaptureAgain,
            );
          }
          if (status != 'scored') {
            return _ProcessingView(onCaptureAgain: onCaptureAgain);
          }

          final nfiqScore = (data['nfiqScore'] as num?)?.toDouble() ?? 0.0;
          final nfiqPass = data['nfiqPass'] as bool? ?? false;
          final henryClass = data['henryClass'] as String? ?? '—';
          final enhancedPath = data['enhancedImagePath'] as String?;

          return _ResultView(
            nfiqScore: nfiqScore,
            nfiqPass: nfiqPass,
            henryClass: henryClass,
            enhancedPath: enhancedPath,
            onCaptureAgain: onCaptureAgain,
          );
        },
      ),
    );
  }
}

class _ProcessingView extends StatelessWidget {
  const _ProcessingView({required this.onCaptureAgain});
  final VoidCallback onCaptureAgain;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: CaptureColors.cyan),
          const SizedBox(height: 16),
          const Text(
            'Scoring capture…',
            style: TextStyle(color: CaptureColors.silverBright, fontSize: 15),
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
  const _ResultView({
    required this.nfiqScore,
    required this.nfiqPass,
    required this.henryClass,
    required this.enhancedPath,
    required this.onCaptureAgain,
  });

  final double nfiqScore;
  final bool nfiqPass;
  final String henryClass;
  final String? enhancedPath;
  final VoidCallback onCaptureAgain;

  @override
  Widget build(BuildContext context) {
    final statusColor = nfiqPass ? CaptureColors.success : CaptureColors.warning;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            if (enhancedPath != null)
              _EnhancedImage(path: enhancedPath!)
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
                color: statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: statusColor.withValues(alpha: 0.4)),
              ),
              child: Column(
                children: [
                  Text(
                    nfiqScore.toStringAsFixed(1),
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 40,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    nfiqPass ? 'NFIQ PASS' : 'NFIQ BELOW THRESHOLD',
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
            const SizedBox(height: 12),
            Text(
              'Henry class: $henryClass',
              style: const TextStyle(color: CaptureColors.silverBright),
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
