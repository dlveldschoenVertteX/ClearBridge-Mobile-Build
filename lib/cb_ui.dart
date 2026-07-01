import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:clearbridge/clearbridge_colors.dart';
import 'package:clearbridge/clearbridge_typography.dart';

// ---------------------------------------------------------------------------
// ClearBridge shared UI — Flutter port of the "Flutter APK UI" prototype
// (Components.jsx). Reuses ClearBridgeColors / ClearBridgeTypography. Icons
// use the built-in Material `Icons` set (no extra dependency).
// ---------------------------------------------------------------------------

enum CbButtonVariant { primary, secondary, ghost, danger }

class CbButton extends StatelessWidget {
  const CbButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = CbButtonVariant.primary,
    this.leadingIcon,
    this.trailingIcon,
    this.disabled = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final CbButtonVariant variant;
  final IconData? leadingIcon;
  final IconData? trailingIcon;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final isPrimary = variant == CbButtonVariant.primary;
    final enabled = !disabled && onPressed != null;

    Color fg;
    Gradient? gradient;
    Color? bg;
    BoxBorder? border;
    List<BoxShadow>? shadow;

    switch (variant) {
      case CbButtonVariant.primary:
        gradient = enabled ? ClearBridgeColors.gradPrimary : null;
        bg = enabled ? null : ClearBridgeColors.cardBorder;
        fg = enabled ? Colors.white : ClearBridgeColors.silverDim;
        shadow = enabled
            ? [BoxShadow(color: ClearBridgeColors.cyan.withValues(alpha: 0.25), blurRadius: 24, offset: const Offset(0, 8))]
            : null;
        break;
      case CbButtonVariant.secondary:
        bg = Colors.transparent;
        fg = ClearBridgeColors.cyan;
        border = Border.all(color: ClearBridgeColors.cyanBorder, width: 1.5);
        break;
      case CbButtonVariant.ghost:
        bg = Colors.white.withValues(alpha: 0.04);
        fg = ClearBridgeColors.silverBright;
        border = Border.all(color: Colors.white.withValues(alpha: 0.08));
        break;
      case CbButtonVariant.danger:
        bg = ClearBridgeColors.error.withValues(alpha: 0.08);
        fg = ClearBridgeColors.error;
        border = Border.all(color: ClearBridgeColors.error.withValues(alpha: 0.5), width: 1.5);
        break;
    }

    return Opacity(
      opacity: enabled || !isPrimary ? 1 : 0.55,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: enabled ? onPressed : null,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
            decoration: BoxDecoration(
              gradient: gradient,
              color: bg,
              borderRadius: BorderRadius.circular(16),
              border: border,
              boxShadow: shadow,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (leadingIcon != null) ...[
                  Icon(leadingIcon, size: 18, color: fg),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    label,
                    style: ClearBridgeTypography.h3.copyWith(
                        color: fg, fontSize: 15, letterSpacing: 0.1),
                  ),
                ),
                if (trailingIcon != null) ...[
                  const SizedBox(width: 8),
                  Icon(trailingIcon, size: 18, color: fg),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum CbPillColor { cyan, gold, green, orange, gray }

class CbPill extends StatelessWidget {
  const CbPill({
    super.key,
    required this.label,
    this.color = CbPillColor.cyan,
    this.dot = false,
  });

  final String label;
  final CbPillColor color;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final fg = switch (color) {
      CbPillColor.cyan => ClearBridgeColors.cyan,
      CbPillColor.gold => ClearBridgeColors.gold,
      CbPillColor.green => ClearBridgeColors.success,
      CbPillColor.orange => ClearBridgeColors.warning,
      CbPillColor.gray => ClearBridgeColors.silverDim,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: fg.withValues(alpha: 0.32)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: fg,
                boxShadow: [BoxShadow(color: fg, blurRadius: 8)],
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            label.toUpperCase(),
            style: ClearBridgeTypography.label
                .copyWith(color: fg, fontWeight: FontWeight.w700, letterSpacing: 0.08),
          ),
        ],
      ),
    );
  }
}

enum CbCardVariant { base, cyan, gold, blue }

class CbCard extends StatelessWidget {
  const CbCard({
    super.key,
    required this.child,
    this.variant = CbCardVariant.base,
    this.padding = const EdgeInsets.all(18),
  });

  final Widget child;
  final CbCardVariant variant;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    Gradient? gradient;
    Color? bg;
    Color borderColor;
    switch (variant) {
      case CbCardVariant.base:
        bg = ClearBridgeColors.cardBg;
        borderColor = ClearBridgeColors.cardBorder;
        break;
      case CbCardVariant.cyan:
        gradient = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [ClearBridgeColors.cyan.withValues(alpha: 0.14), ClearBridgeColors.cyan.withValues(alpha: 0.04)],
        );
        borderColor = ClearBridgeColors.cyan.withValues(alpha: 0.32);
        break;
      case CbCardVariant.gold:
        gradient = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [ClearBridgeColors.gold.withValues(alpha: 0.18), ClearBridgeColors.gold.withValues(alpha: 0.06)],
        );
        borderColor = ClearBridgeColors.gold.withValues(alpha: 0.32);
        break;
      case CbCardVariant.blue:
        gradient = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [ClearBridgeColors.blueDark.withValues(alpha: 0.16), ClearBridgeColors.blueDark.withValues(alpha: 0.04)],
        );
        borderColor = ClearBridgeColors.blueDark.withValues(alpha: 0.32);
        break;
    }
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        gradient: gradient,
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: borderColor),
      ),
      child: child,
    );
  }
}

class CbInputField extends StatefulWidget {
  const CbInputField({
    super.key,
    required this.label,
    this.controller,
    this.hintText,
    this.keyboardType,
    this.onChanged,
  });

  final String label;
  final TextEditingController? controller;
  final String? hintText;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;

  @override
  State<CbInputField> createState() => _CbInputFieldState();
}

class _CbInputFieldState extends State<CbInputField> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    final accent = focused ? ClearBridgeColors.cyan : ClearBridgeColors.silverDim;
    return Container(
      decoration: BoxDecoration(
        color: focused
            ? ClearBridgeColors.cyan.withValues(alpha: 0.04)
            : Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: focused ? ClearBridgeColors.cyan : Colors.white.withValues(alpha: 0.08),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 9, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.label.toUpperCase(),
            style: ClearBridgeTypography.label.copyWith(
                color: accent, fontWeight: FontWeight.w700, letterSpacing: 0.08, fontSize: 10),
          ),
          TextField(
            controller: widget.controller,
            focusNode: _focus,
            keyboardType: widget.keyboardType,
            onChanged: widget.onChanged,
            style: ClearBridgeTypography.body.copyWith(
                color: ClearBridgeColors.silverBright, fontSize: 15, fontWeight: FontWeight.w600),
            cursorColor: ClearBridgeColors.cyan,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.only(top: 6),
              border: InputBorder.none,
              hintText: widget.hintText,
              hintStyle: ClearBridgeTypography.body
                  .copyWith(color: ClearBridgeColors.silverDim, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }
}

class BetaBadge extends StatelessWidget {
  const BetaBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: ClearBridgeColors.gold.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: ClearBridgeColors.gold.withValues(alpha: 0.4)),
      ),
      child: Text('BETA',
          style: ClearBridgeTypography.label.copyWith(
              color: ClearBridgeColors.gold,
              fontWeight: FontWeight.w800,
              fontSize: 9,
              letterSpacing: 0.14)),
    );
  }
}

class CbAvatar extends StatelessWidget {
  const CbAvatar({super.key, this.initials = 'CB', this.onTap, this.size = 44});

  final String initials;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [ClearBridgeColors.cyan, ClearBridgeColors.blueDeep2],
          ),
          border: Border.all(color: ClearBridgeColors.cyanBorder, width: 2),
        ),
        alignment: Alignment.center,
        child: Text(initials,
            style: ClearBridgeTypography.h3
                .copyWith(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
      ),
    );
  }
}

class CbBottomNavItem {
  const CbBottomNavItem(this.id, this.icon, this.label);
  final String id;
  final IconData icon;
  final String label;
}

class CbBottomNav extends StatelessWidget {
  const CbBottomNav({super.key, required this.active, required this.onNav, this.items});

  final String active;
  final ValueChanged<String> onNav;
  final List<CbBottomNavItem>? items;

  static const _defaults = [
    CbBottomNavItem('home', Icons.home_rounded, 'Home'),
    CbBottomNavItem('profile', Icons.person_rounded, 'Profile'),
  ];

  @override
  Widget build(BuildContext context) {
    final navItems = items ?? _defaults;
    return Container(
      decoration: BoxDecoration(
        color: ClearBridgeColors.steel.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 24, offset: const Offset(0, 8))],
      ),
      padding: const EdgeInsets.all(5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in navItems)
            GestureDetector(
              onTap: () => onNav(item.id),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(100),
                  gradient: active == item.id
                      ? LinearGradient(colors: [
                          ClearBridgeColors.cyan.withValues(alpha: 0.18),
                          ClearBridgeColors.blueDark.withValues(alpha: 0.10),
                        ])
                      : null,
                  border: Border.all(
                    color: active == item.id
                        ? ClearBridgeColors.cyan.withValues(alpha: 0.4)
                        : Colors.transparent,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(item.icon,
                        size: 18,
                        color: active == item.id
                            ? ClearBridgeColors.cyan
                            : ClearBridgeColors.silverDim),
                    const SizedBox(width: 6),
                    Text(item.label,
                        style: ClearBridgeTypography.caption.copyWith(
                          color: active == item.id
                              ? ClearBridgeColors.cyan
                              : ClearBridgeColors.silverDim,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        )),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The ClearCoin gold coin, ported from the prototype SVG (`ClearCoinSVG`).
class ClearCoinCoin extends StatelessWidget {
  const ClearCoinCoin({super.key, this.size = 52});
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _CoinPainter()),
    );
  }
}

class _CoinPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 52.0; // scale from the 52px source viewBox
    Offset p(double x, double y) => Offset(x * s, y * s);
    double r(double v) => v * s;

    // Drop shadow
    canvas.drawCircle(p(26, 28), r(23), Paint()..color = Colors.black.withValues(alpha: 0.35));
    // Edge / depth
    canvas.drawCircle(
      p(26, 26),
      r(24),
      Paint()
        ..shader = const RadialGradient(
          colors: [ClearBridgeColors.gold, Color(0xFF5C3A08)],
        ).createShader(Rect.fromCircle(center: p(26, 26), radius: r(24))),
    );
    // Face
    canvas.drawCircle(
      p(26, 25),
      r(22),
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.24, -0.44),
          radius: 0.68,
          colors: [Color(0xFFFAE07A), Color(0xFFC9A84C), Color(0xFF7A5010)],
          stops: [0.0, 0.45, 1.0],
        ).createShader(Rect.fromCircle(center: p(26, 25), radius: r(22))),
    );
    // Inner rim
    canvas.drawCircle(
      p(26, 25),
      r(18),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r(1.5)
        ..color = const Color(0xFFFFE678).withValues(alpha: 0.35),
    );
    // CC lettering
    final tp = TextPainter(
      text: TextSpan(
        text: 'CC',
        style: TextStyle(
          fontSize: r(13),
          fontWeight: FontWeight.w900,
          letterSpacing: r(-0.5),
          color: const Color(0xFF502800).withValues(alpha: 0.85),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, p(26, 25) - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_CoinPainter old) => false;
}

/// Animated scan line that sweeps vertically within a viewfinder.
class CbScanLine extends StatefulWidget {
  const CbScanLine({super.key, this.color});
  final Color? color;

  @override
  State<CbScanLine> createState() => _CbScanLineState();
}

class _CbScanLineState extends State<CbScanLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? ClearBridgeColors.cyan;
    return LayoutBuilder(
      builder: (context, constraints) {
        return AnimatedBuilder(
          animation: _c,
          builder: (_, __) {
            final t = Curves.easeInOut.transform(_c.value);
            final y = 20 + (constraints.maxHeight - 40) * t;
            return Stack(
              children: [
                Positioned(
                  left: 12,
                  right: 12,
                  top: y,
                  child: Container(
                    height: 2,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [
                        Colors.transparent,
                        color,
                        Colors.transparent,
                      ]),
                      boxShadow: [BoxShadow(color: color, blurRadius: 18)],
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Cyan corner-bracket accents for a viewfinder (4 corners).
class CbCornerBrackets extends StatelessWidget {
  const CbCornerBrackets({super.key, this.color, this.size = 22, this.thickness = 3});
  final Color? color;
  final double size;
  final double thickness;

  @override
  Widget build(BuildContext context) {
    final c = color ?? ClearBridgeColors.cyan;
    Widget corner(bool top, bool left) => CustomPaint(
          size: Size(size, size),
          painter: _BracketPainter(c, thickness, top, left),
        );
    return Stack(children: [
      Positioned(top: -2, left: -2, child: corner(true, true)),
      Positioned(top: -2, right: -2, child: corner(true, false)),
      Positioned(bottom: -2, left: -2, child: corner(false, true)),
      Positioned(bottom: -2, right: -2, child: corner(false, false)),
    ]);
  }
}

class _BracketPainter extends CustomPainter {
  final Color color;
  final double width;
  final bool top, left;
  const _BracketPainter(this.color, this.width, this.top, this.left);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final path = Path();
    final x = left ? 0.0 : size.width;
    final y = top ? 0.0 : size.height;
    final dx = left ? size.width : -size.width;
    final dy = top ? size.height : -size.height;
    path.moveTo(x + dx, y);
    path.lineTo(x, y);
    path.lineTo(x, y + dy);
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(_BracketPainter old) => false;
}

/// Dashed rounded-rect border painter (for the capture viewfinder frame).
class CbDashedRRect extends StatelessWidget {
  const CbDashedRRect({super.key, required this.color, this.radius = 24, this.child});
  final Color color;
  final double radius;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedRRectPainter(color, radius),
      child: child,
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  final Color color;
  final double radius;
  const _DashedRRectPainter(this.color, this.radius);

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
        Offset.zero & size, Radius.circular(radius));
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path()..addRRect(rrect);
    const dash = 8.0, gap = 6.0;
    for (final metric in path.computeMetrics()) {
      double dist = 0;
      while (dist < metric.length) {
        canvas.drawPath(
          metric.extractPath(dist, math.min(dist + dash, metric.length)),
          paint,
        );
        dist += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter old) =>
      old.color != color || old.radius != radius;
}
