import 'package:flutter/material.dart';

/// The launch mark: the app badge settles in with a soft glow.
class StartupLogo extends StatefulWidget {
  const StartupLogo({super.key, this.size = 112});

  final double size;

  @override
  State<StartupLogo> createState() => _StartupLogoState();
}

class _StartupLogoState extends State<StartupLogo> with TickerProviderStateMixin {
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
        final reveal = _segment(_entry.value, 0.05, 0.72, Curves.easeOutCubic);
        final breathe = Curves.easeInOutSine.transform(_glow.value);
        final glowAlpha = reveal * (0.08 + 0.05 * breathe);
        final glowBlur = 22.0 + 10.0 * breathe;

        return Container(
          width: widget.size,
          height: widget.size,
          clipBehavior: Clip.antiAlias,
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
          child: Opacity(
            opacity: reveal,
            child: Transform.scale(scale: 0.94 + 0.06 * reveal, child: child),
          ),
        );
      },
      child: SizedBox.square(
        dimension: widget.size,
        child: Image.asset('assets/images/app_logo.png', fit: BoxFit.cover),
      ),
    );
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
