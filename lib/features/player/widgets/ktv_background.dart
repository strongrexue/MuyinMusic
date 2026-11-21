import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/settings_store.dart';
import '../../../core/ui/flow_palette.dart';
import '../player_controller.dart';
import 'player_control_color.dart';

Color _dim(Color color, double factor) =>
    Color.lerp(Colors.black, color, factor)!;

/// 横屏 KTV 播放页背景：流光渐变 / 封面柔焦 / 自定义图片三选一，
/// 由 [AppSettings.ktvBackgroundStyle] 决定。无封面或自定义图缺失时
/// 回退到流光渐变；无当前歌曲时用 [FlowPalette.fallback] 调色。
class KtvBackground extends ConsumerWidget {
  const KtvBackground({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = ref.watch(
      settingsProvider.select((s) => s.ktvBackgroundStyle),
    );
    final customPath = ref.watch(
      settingsProvider.select((s) => s.ktvBackgroundImagePath),
    );
    final imageProvider = ref.watch(playerArtworkProvider);
    final artworkColors = ref.watch(playerArtworkColorsProvider);
    final hasTrack = ref.watch(
      playerControllerProvider.select((s) => s.track != null),
    );
    final playing = ref.watch(
      playerControllerProvider.select((s) => s.playing),
    );
    final animate = playing && !MediaQuery.disableAnimationsOf(context);
    final palette = hasTrack ? artworkColors.valueOrNull?.palette : null;

    final Widget child;
    switch (style) {
      case KtvBackgroundStyle.custom:
        final file = customPath == null || customPath.isEmpty
            ? null
            : File(customPath);
        child = file != null && file.existsSync()
            ? _CustomBackground(file: file)
            : _GradientBackground(palette: palette, animate: animate);
      case KtvBackgroundStyle.cover:
        child = imageProvider != null
            ? _CoverBackground(imageProvider: imageProvider, animate: animate)
            : _GradientBackground(palette: palette, animate: animate);
      case KtvBackgroundStyle.gradient:
        child = _GradientBackground(palette: palette, animate: animate);
    }
    return RepaintBoundary(child: child);
  }
}

/// 底部渐隐黑幕，保证歌词在任何背景上可读。
class _BottomScrim extends StatelessWidget {
  const _BottomScrim();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Color(0x73000000)],
          stops: [0.55, 1.0],
        ),
      ),
    );
  }
}

class _GradientBackground extends StatefulWidget {
  const _GradientBackground({required this.palette, required this.animate});

  /// 当前歌曲的取色；为 null 表示尚未就绪，沿用上一次取色或 fallback。
  final FlowPalette? palette;
  final bool animate;

  @override
  State<_GradientBackground> createState() => _GradientBackgroundState();
}

class _GradientBackgroundState extends State<_GradientBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  );
  FlowPalette? _lastPalette;

  @override
  void initState() {
    super.initState();
    _lastPalette = widget.palette;
    _syncAnimation();
  }

  @override
  void didUpdateWidget(_GradientBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.palette != null) _lastPalette = widget.palette;
    _syncAnimation();
  }

  void _syncAnimation() {
    if (widget.animate) {
      if (!_drift.isAnimating) _drift.repeat(reverse: true);
    } else {
      _drift.stop();
    }
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette ?? _lastPalette ?? FlowPalette.fallback;
    final base = _dim(Color(palette.baseArgb), 0.60);
    final accent0 = _dim(Color(palette.accentsArgb[0]), 0.62);
    final accent1 = _dim(Color(palette.accentsArgb[1]), 0.58);
    final glow = Color(palette.accentsArgb[2]);
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeInOut,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [base, accent0, accent1],
              stops: const [0.0, 0.55, 1.0],
            ),
          ),
        ),
        AnimatedBuilder(
          animation: _drift,
          builder: (context, _) {
            final t = Curves.easeInOut.transform(_drift.value);
            return Positioned.fill(
              child: Align(
                alignment: Alignment(-0.6 + 1.2 * t, -0.7 + 0.9 * t),
                child: FractionallySizedBox(
                  widthFactor: 1.1,
                  heightFactor: 0.9,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        colors: [
                          glow.withValues(alpha: 0.42),
                          glow.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        const _BottomScrim(),
      ],
    );
  }
}

class _CoverBackground extends StatefulWidget {
  const _CoverBackground({required this.imageProvider, required this.animate});

  final ImageProvider<Object> imageProvider;
  final bool animate;

  @override
  State<_CoverBackground> createState() => _CoverBackgroundState();
}

class _CoverBackgroundState extends State<_CoverBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _kenBurns = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 36),
  );

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(_CoverBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  void _syncAnimation() {
    if (widget.animate) {
      if (!_kenBurns.isAnimating) _kenBurns.repeat(reverse: true);
    } else {
      _kenBurns.stop();
    }
  }

  @override
  void dispose() {
    _kenBurns.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRect(
          child: AnimatedBuilder(
            animation: _kenBurns,
            builder: (context, child) {
              final t = Curves.easeInOut.transform(_kenBurns.value);
              return Transform.translate(
                offset: Offset(-14 + 28 * t, -8 + 16 * t),
                child: Transform.scale(scale: 1.06 + 0.08 * t, child: child),
              );
            },
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 9, sigmaY: 9),
              child: Image(
                image: widget.imageProvider,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            ),
          ),
        ),
        const ColoredBox(color: Color(0x57000000)),
        const _BottomScrim(),
      ],
    );
  }
}

class _CustomBackground extends StatelessWidget {
  const _CustomBackground({required this.file});

  final File file;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image(image: FileImage(file), fit: BoxFit.cover, gaplessPlayback: true),
        const ColoredBox(color: Color(0x61000000)),
        const _BottomScrim(),
      ],
    );
  }
}
