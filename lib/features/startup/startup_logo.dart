import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_motion.dart';

/// The launch mark: a mint sound ring draws itself, then the note settles in.
class StartupLogo extends StatefulWidget {
  const StartupLogo({super.key, this.size = 112});

  final double size;

  @override
  State<StartupLogo> createState() => _StartupLogoState();
}

class _StartupLogoState extends State<StartupLogo> with TickerProviderStateMixin {
  static const Color _ringColor = Color(0xFF7FD7BE);

  late final AnimationController _entry = AnimationController(
    duration: const Duration(milliseconds: 1200),
    vsync: this,
  );
  late final AnimationController _glow = AnimationController(
    duration: const Duration(milliseconds: 2400),
    vsync: this,
  );

  @override
  void initState() {
    super.initState();
    _entry
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          _glow.repeat(reverse: true);
        }
      })
      ..forward();
  }

  @override
  void dispose() {
    _entry.dispose();
    _glow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AnimatedBuilder(
      animation: Listenable.merge([_entry, _glow]),
      builder: (context, child) {
        final ring = _segment(_entry.value, 0.0, 0.72, AppMotion.emphasizedDecelerate);
        final reveal = _segment(_entry.value, 0.58, 0.96, Curves.easeOutCubic);
        final breathe = Curves.easeInOutSine.transform(_glow.value);
        final glowAlpha = reveal * (0.08 + 0.05 * breathe);
        final glowBlur = 22.0 + 10.0 * breathe;

        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(widget.size * 0.24),
            boxShadow: [
              BoxShadow(
                color: scheme.shadow.withValues(
                  alpha: scheme.brightness == Brightness.light ? 0.16 : 0.34,
                ),
                blurRadius: 22,
                offset: const Offset(0, 12),
              ),
              BoxShadow(
                color: scheme.primary.withValues(alpha: glowAlpha),
                blurRadius: glowBlur,
                spreadRadius: 1,
              ),
              BoxShadow(
                color: scheme.tertiary.withValues(alpha: glowAlpha * 0.7),
                blurRadius: glowBlur * 0.8,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(
                painter: _RingPainter(progress: ring, color: _ringColor),
              ),
              Opacity(
                opacity: reveal,
                child: Transform.scale(scale: 0.94 + 0.06 * reveal, child: child),
              ),
            ],
          ),
        );
      },
      child: Padding(
        padding: EdgeInsets.all(widget.size * 0.05),
        child: Image.asset('logo_fg.png', fit: BoxFit.contain),
      ),
    );
  }
}

/// Draws the sound ring: an arc that sweeps clockwise, then its bead.
class _RingPainter extends CustomPainter {
  const _RingPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;

    final center = size.center(Offset.zero);
    final radius = size.shortestSide * 0.43;
    final stroke = math.max(1.6, size.shortestSide * 0.022);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke
      ..color = color;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * progress.clamp(0.0, 1.0),
      false,
      paint,
    );

    final bead = _segment(progress, 0.86, 1.0);
    if (bead > 0) {
      canvas.drawCircle(
        center + Offset(0, radius),
        stroke * 1.55 * bead,
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

double _segment(
  double t,
  double start,
  double end, [
  Curve curve = Curves.easeInOutCubic,
]) {
  return curve.transform(((t - start) / (end - start)).clamp(0.0, 1.0));
}
