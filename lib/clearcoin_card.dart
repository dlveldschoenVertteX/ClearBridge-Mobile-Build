import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:clearbridge/clearbridge_colors.dart';
import 'package:clearbridge/clearcoin_service.dart';

class ClearCoinCard extends ConsumerWidget {
  const ClearCoinCard({super.key, this.coinsOverride});

  final int? coinsOverride;

  static const int _totalMax = ClearCoinService.totalMax; // 60
  static const int _captureMax = ClearCoinService.captureMax; // 50
  static const int _perSession = ClearCoinService.perSession; // 10
  static const int _sessions = ClearCoinService.sessionsToMax; // 5

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int rawCoins = coinsOverride ?? ref.watch(clearCoinBalanceProvider);
    final int coins = rawCoins.clamp(0, _totalMax);
    final sessionsDone = (coins.clamp(0, _captureMax) / _perSession).floor();
    final referralClaimed = ref.watch(referralClaimedProvider);
    final isMax = coins >= _totalMax;

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: ClearBridgeColors.gold.withValues(alpha: 0.32)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          stops: const [0.0, 0.6, 1.0],
          colors: [
            ClearBridgeColors.gold.withValues(alpha: 0.13),
            ClearBridgeColors.goldDark.withValues(alpha: 0.06),
            ClearBridgeColors.steel.withValues(alpha: 0.55),
          ],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -30,
            left: -20,
            child: IgnorePointer(
              child: Container(
                width: 140,
                height: 140,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      ClearBridgeColors.gold.withValues(alpha: 0.16),
                      ClearBridgeColors.gold.withValues(alpha: 0.0),
                    ],
                    stops: const [0.0, 0.7],
                  ),
                ),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _topRow(coins, isMax),
              const SizedBox(height: 12),
              _sectionLabel('Capture Sessions'),
              const SizedBox(height: 5),
              _pipsRow(sessionsDone),
              const SizedBox(height: 10),
              _sectionLabel('Referral Bonus'),
              const SizedBox(height: 5),
              _referralPip(referralClaimed),
              const SizedBox(height: 10),
              const Divider(height: 1, color: Color(0x24C9A84C)),
              const SizedBox(height: 10),
              _redeemRow(coins, isMax),
              if (isMax) ...[
                const SizedBox(height: 8),
                _expiryRow(),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Text(
        text.toUpperCase(),
        style: GoogleFonts.manrope(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.10,
          color: ClearBridgeColors.silverDim,
        ),
      );

  Widget _topRow(int coins, bool isMax) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _RingGauge(coins: coins, max: _totalMax, isMax: isMax),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    'ClearCoin',
                    style: GoogleFonts.manrope(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: ClearBridgeColors.goldLight,
                    ),
                  ),
                  const SizedBox(width: 6),
                  _miniBetaBadge(),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.fingerprint,
                      size: 12, color: ClearBridgeColors.gold),
                  const SizedBox(width: 5),
                  Text(
                    '+$_perSession per capture session',
                    style: GoogleFonts.manrope(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      height: 1.5,
                      color: ClearBridgeColors.silver,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  const Icon(Icons.share,
                      size: 12, color: ClearBridgeColors.gold),
                  const SizedBox(width: 5),
                  Text(
                    '+10 when referral buys',
                    style: GoogleFonts.manrope(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      height: 1.5,
                      color: ClearBridgeColors.silver,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'BALANCE',
              style: GoogleFonts.manrope(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.08,
                color: ClearBridgeColors.silverDim,
              ),
            ),
            const SizedBox(height: 2),
            RichText(
              text: TextSpan(
                text: '$coins',
                style: GoogleFonts.manrope(
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                  height: 1.1,
                  color: isMax
                      ? ClearBridgeColors.gold
                      : ClearBridgeColors.goldLight,
                  shadows: isMax
                      ? [
                          Shadow(
                            color: ClearBridgeColors.gold.withValues(alpha: 0.65),
                            blurRadius: 16,
                          ),
                        ]
                      : null,
                ),
                children: [
                  TextSpan(
                    text: '/$_totalMax',
                    style: GoogleFonts.manrope(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: ClearBridgeColors.silverDim,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'R$coins OFF',
              style: GoogleFonts.manrope(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.08,
                color: ClearBridgeColors.gold,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _miniBetaBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: ClearBridgeColors.gold.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: ClearBridgeColors.gold.withValues(alpha: 0.4)),
      ),
      child: Text(
        'BETA',
        style: GoogleFonts.manrope(
          fontSize: 8,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.1,
          color: ClearBridgeColors.gold,
        ),
      ),
    );
  }

  Widget _pipsRow(int sessionsDone) {
    return SizedBox(
      height: 18,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < _sessions; i++) ...[
            Expanded(child: _pip(done: i < sessionsDone)),
            if (i != _sessions - 1) const SizedBox(width: 4),
          ],
        ],
      ),
    );
  }

  Widget _pip({required bool done}) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        gradient: done
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  ClearBridgeColors.gold.withValues(alpha: 0.40),
                  ClearBridgeColors.goldLight.withValues(alpha: 0.18),
                ],
              )
            : null,
        color: done ? null : Colors.white.withValues(alpha: 0.04),
        border: Border.all(
          color: done
              ? ClearBridgeColors.gold.withValues(alpha: 0.5)
              : Colors.white.withValues(alpha: 0.06),
        ),
        boxShadow: done
            ? [
                BoxShadow(
                  color: ClearBridgeColors.gold.withValues(alpha: 0.25),
                  blurRadius: 8,
                ),
              ]
            : null,
      ),
      alignment: Alignment.center,
      child: done
          ? Text(
              '+$_perSession',
              style: GoogleFonts.manrope(
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.04,
                color: ClearBridgeColors.goldLight,
              ),
            )
          : Icon(Icons.fingerprint,
              size: 11, color: Colors.white.withValues(alpha: 0.20)),
    );
  }

  Widget _referralPip(bool claimed) {
    if (claimed) {
      return Container(
        height: 18,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              ClearBridgeColors.gold.withValues(alpha: 0.40),
              ClearBridgeColors.goldLight.withValues(alpha: 0.18),
            ],
          ),
          border: Border.all(color: ClearBridgeColors.gold.withValues(alpha: 0.5)),
          boxShadow: [
            BoxShadow(
              color: ClearBridgeColors.gold.withValues(alpha: 0.25),
              blurRadius: 8,
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.share, size: 10, color: ClearBridgeColors.goldLight),
            const SizedBox(width: 5),
            Text(
              '+${ClearCoinService.referralMax} — Claimed!',
              style: GoogleFonts.manrope(
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.04,
                color: ClearBridgeColors.goldLight,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      height: 18,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: Colors.white.withValues(alpha: 0.04),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      alignment: Alignment.center,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.share, size: 10, color: ClearBridgeColors.gold.withValues(alpha: 0.55)),
          const SizedBox(width: 6),
          Text(
            'Unlocks when your referral purchases a clearance',
            style: GoogleFonts.manrope(
              fontSize: 9,
              fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: 0.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _redeemRow(int coins, bool isMax) {
    return Row(
      children: [
        const Icon(Icons.local_offer,
            size: 13, color: ClearBridgeColors.gold),
        const SizedBox(width: 5),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: GoogleFonts.manrope(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: ClearBridgeColors.silver,
              ),
              children: [
                TextSpan(
                  text: '1 ClearCoin = R1 off',
                  style: GoogleFonts.manrope(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: ClearBridgeColors.goldLight,
                  ),
                ),
                const TextSpan(text: ' your clearance'),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          isMax ? 'MAX REACHED' : 'Max R$_totalMax',
          style: GoogleFonts.manrope(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            color: ClearBridgeColors.goldLight,
          ),
        ),
      ],
    );
  }

  Widget _expiryRow() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: ClearBridgeColors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: ClearBridgeColors.warning.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: [
          const Icon(Icons.timer,
              size: 13, color: ClearBridgeColors.warning),
          const SizedBox(width: 6),
          Text.rich(
            TextSpan(
              style: GoogleFonts.manrope(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: ClearBridgeColors.warning,
              ),
              children: [
                const TextSpan(text: 'Expires in '),
                TextSpan(
                  text: '28 days',
                  style: GoogleFonts.manrope(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    color: ClearBridgeColors.warning,
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

class _RingGauge extends StatelessWidget {
  const _RingGauge({
    required this.coins,
    required this.max,
    required this.isMax,
  });

  final int coins;
  final int max;
  final bool isMax;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      height: 72,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _RingGaugePainter(
                fraction: max > 0 ? coins / max : 0.0,
                isMax: isMax,
              ),
            ),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$coins',
                  style: GoogleFonts.manrope(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.4,
                    height: 1.1,
                    color: ClearBridgeColors.goldLight,
                  ),
                ),
                Text(
                  'coins',
                  style: GoogleFonts.manrope(
                    fontSize: 7,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.06,
                    color: ClearBridgeColors.silverDim,
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

class _RingGaugePainter extends CustomPainter {
  final double fraction;
  final bool isMax;

  const _RingGaugePainter({required this.fraction, required this.isMax});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    const strokeWidth = 5.0;
    final radius = size.width / 2 - strokeWidth / 2;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = ClearBridgeColors.gold.withValues(alpha: 0.10)
        ..strokeWidth = strokeWidth
        ..style = PaintingStyle.stroke,
    );

    if (fraction > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * fraction,
        false,
        Paint()
          ..color = isMax ? ClearBridgeColors.gold : ClearBridgeColors.goldLight
          ..strokeWidth = strokeWidth
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      );
    }
  }

  @override
  bool shouldRepaint(_RingGaugePainter old) =>
      old.fraction != fraction || old.isMax != isMax;
}
