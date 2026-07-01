import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:clearbridge/clearbridge_colors.dart';
import 'package:clearbridge/clearbridge_typography.dart';
import 'package:clearbridge/clearance_provider.dart';
import 'package:clearbridge/auth_provider.dart';
import 'package:clearbridge/henry_class_utils.dart';

class FingerprintIdentityCard extends ConsumerWidget {
  const FingerprintIdentityCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Guard: don't show anything while auth is still loading — prevents the
    // premature TeaserCard flash that causes the jitter during sign-in.
    if (ref.watch(authProvider).valueOrNull == null) return const SizedBox.shrink();

    final captureAsync = ref.watch(lastScoredCaptureProvider);

    return captureAsync.when(
      loading: () => const SizedBox.shrink(),
      error:   (_, __) => const SizedBox.shrink(),
      data:    (capture) => capture != null
          ? _IdentityCard(capture: capture)
          : const _TeaserCard(),
    );
  }
}

// ── Teaser — shown when user has no captures yet ──────────────────────────────

class _TeaserCard extends StatelessWidget {
  const _TeaserCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0D1C3A), Color(0xFF0A1428)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: ClearBridgeColors.cyan.withValues(alpha: 0.12)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: ClearBridgeColors.cyan.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: ClearBridgeColors.cyan.withValues(alpha: 0.20)),
            ),
            child: Icon(Icons.fingerprint,
                size: 24, color: ClearBridgeColors.cyan.withValues(alpha: 0.70)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your Fingerprint Identity',
                  style: ClearBridgeTypography.body.copyWith(
                    color: ClearBridgeColors.silverBright,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Capture your print to discover what makes it uniquely yours.',
                  style: ClearBridgeTypography.caption.copyWith(
                    color: ClearBridgeColors.silverDim,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Full identity card — shown after first scored capture ─────────────────────

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.capture});

  final Map<String, dynamic> capture;

  @override
  Widget build(BuildContext context) {
    final code      = (capture['henryClass'] as String?) ?? '—';
    final nfiq      = (capture['nfiqScore']  as num?)?.toDouble() ?? 0.0;
    final coverage  = (capture['sfmCoverage'] as num?)?.toDouble() ?? 0.0;
    final accent    = HenryClassUtils.accentColor(code);
    final label     = HenryClassUtils.label(code);
    final snippet   = HenryClassUtils.snippet(code);
    final iconData  = HenryClassUtils.icon(code);
    final fact      = HenryClassUtils.dailyFact();
    final coveragePct = (coverage * 100).round();

    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0D1C3A), Color(0xFF0A1428)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.20)),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.06),
            blurRadius: 20,
            spreadRadius: 0,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ─────────────────────────────────────────────────
            Row(
              children: [
                Icon(Icons.biotech_rounded,
                    size: 14, color: accent.withValues(alpha: 0.70)),
                const SizedBox(width: 6),
                Text(
                  'FINGERPRINT IDENTITY',
                  style: ClearBridgeTypography.label.copyWith(
                    color: accent.withValues(alpha: 0.80),
                    fontWeight: FontWeight.w800,
                    fontSize: 10,
                    letterSpacing: 0.18,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 14),

            // ── Pattern type + snippet ──────────────────────────────────
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: accent.withValues(alpha: 0.22)),
                  ),
                  child: Icon(iconData, size: 20, color: accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ShaderMask(
                    shaderCallback: (bounds) => LinearGradient(
                      colors: [accent, ClearBridgeColors.silverBright],
                    ).createShader(bounds),
                    child: Text(
                      label,
                      style: ClearBridgeTypography.h2.copyWith(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            Container(
              padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: accent.withValues(alpha: 0.12)),
              ),
              child: Text(
                snippet,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.62),
                  fontSize: 12,
                  height: 1.55,
                ),
              ),
            ),

            const SizedBox(height: 14),

            // ── NFIQ + coverage metrics ─────────────────────────────────
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('NFIQ',
                              style: ClearBridgeTypography.label.copyWith(
                                color: ClearBridgeColors.silverDim,
                                fontSize: 10,
                                letterSpacing: 0.10,
                              )),
                          Text(
                            nfiq.toStringAsFixed(0),
                            style: TextStyle(
                              color: accent,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: (nfiq / 100).clamp(0.0, 1.0),
                          minHeight: 5,
                          backgroundColor: Colors.white.withValues(alpha: 0.08),
                          valueColor: AlwaysStoppedAnimation<Color>(accent),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('3D',
                        style: ClearBridgeTypography.label.copyWith(
                          color: ClearBridgeColors.silverDim,
                          fontSize: 10,
                          letterSpacing: 0.10,
                        )),
                    const SizedBox(height: 2),
                    Text(
                      '$coveragePct%',
                      style: TextStyle(
                        color: coverage >= 0.70
                            ? ClearBridgeColors.success
                            : coverage >= 0.45
                                ? ClearBridgeColors.warning
                                : ClearBridgeColors.error,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 14),

            // ── Daily fact ──────────────────────────────────────────────
            const Divider(height: 1, color: Color(0x14FFFFFF)),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 13),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('💡', style: TextStyle(fontSize: 13)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'DID YOU KNOW?',
                          style: ClearBridgeTypography.label.copyWith(
                            color: ClearBridgeColors.gold,
                            fontWeight: FontWeight.w800,
                            fontSize: 9,
                            letterSpacing: 0.18,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          fact,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.58),
                            fontSize: 12,
                            height: 1.50,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
