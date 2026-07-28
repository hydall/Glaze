import 'dart:math';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/theme/app_colors.dart';
import '../../shared/shell/shell_header_provider.dart';

final _random = Random();

class _Star {
  final double x;
  final double y;
  final double size;
  final double opacity;
  final int twinkleMs;
  final int delayMs;

  const _Star({
    required this.x,
    required this.y,
    required this.size,
    required this.opacity,
    required this.twinkleMs,
    required this.delayMs,
  });
}

class _Snowflake {
  final double x;
  final double size;
  final double opacity;
  final double speed;
  final double initialY;

  const _Snowflake({
    required this.x,
    required this.size,
    required this.opacity,
    required this.speed,
    required this.initialY,
  });
}

class HallOfFameScreen extends ConsumerStatefulWidget {
  const HallOfFameScreen({super.key});

  @override
  ConsumerState<HallOfFameScreen> createState() => _HallOfFameScreenState();
}

class _HallOfFameScreenState extends ConsumerState<HallOfFameScreen>
    with TickerProviderStateMixin, ShellHeaderMixin {
  late final AnimationController _master;
  late final Animation<double> _bgOpacity;
  late final Animation<double> _starsOpacity;
  late final Animation<double> _crawlProgress;
  late final AnimationController _starsPulse;
  late final AnimationController _snowfall;
  late final AnimationController _crawl;

  @override
  int get headerBranchIndex => 3;

  bool _showHeaderForExit = false;

  @override
  ShellHeaderConfig buildShellHeader() =>
      ShellHeaderConfig(hidden: !_showHeaderForExit);

  final List<_Star> _starSeed = [];
  final List<_Snowflake> _snowflakes = [];
  final List<String> _testers = [
    'Саша Белый',
    'múrx',
    'lina',
    'ShikiN',
    'N K',
    'Сатаник1155',
    'nightsyr',
  ];

  @override
  void initState() {
    super.initState();

    for (int i = 0; i < 240; i++) {
      _starSeed.add(_Star(
        x: _random.nextDouble(),
        y: _random.nextDouble(),
        size: 0.8 + _random.nextDouble() * 2.4,
        opacity: 0.2 + _random.nextDouble() * 0.8,
        twinkleMs: 1200 + _random.nextInt(2800),
        delayMs: (600 * _random.nextDouble()).round(),
      ));
    }

    for (int i = 0; i < 70; i++) {
      _snowflakes.add(_Snowflake(
        x: _random.nextDouble(),
        size: 1.0 + _random.nextDouble() * 2.5,
        opacity: 0.15 + _random.nextDouble() * 0.5,
        speed: 0.3 + _random.nextDouble() * 0.7,
        initialY: -0.05 - _random.nextDouble() * 0.1,
      ));
    }

    _master = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );

    _bgOpacity = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _master,
        curve: const Interval(0.0, 0.55, curve: Curves.easeOut),
      ),
    );

    _starsOpacity = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _master,
        curve: const Interval(0.25, 1.0, curve: Curves.easeOut),
      ),
    );

    _crawlProgress = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _master,
        curve: const Interval(0.4, 1.0, curve: Curves.easeIn),
      ),
    );

    _starsPulse = AnimationController(
      duration: const Duration(seconds: 3),
      vsync: this,
    )..repeat(reverse: true);

    _snowfall = AnimationController(
      duration: const Duration(seconds: 8),
      vsync: this,
    )..repeat();

    _crawl = AnimationController(
      duration: const Duration(seconds: 22),
      vsync: this,
    );

    _master.forward();
  }

  @override
  void dispose() {
    _master.dispose();
    _starsPulse.dispose();
    _snowfall.dispose();
    _crawl.dispose();
    super.dispose();
  }

  void _close() {
    _showHeaderForExit = true;
    refreshShellHeader();
    _master.reverse().then((_) {
      if (mounted) context.go('/menu/about');
    });
  }

  @override
  Widget build(BuildContext context) {
    final accent = context.colors.accent;
    final size = MediaQuery.sizeOf(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: AnimatedBuilder(
        animation: _master,
        builder: (context, child) {
          return Scaffold(
            backgroundColor: Colors.transparent,
            resizeToAvoidBottomInset: false,
            body: GestureDetector(
              onTap: _close,
              behavior: HitTestBehavior.opaque,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _StarField(
                    stars: _starSeed,
                    opacity: _starsOpacity.value,
                    pulse: _starsPulse,
                  ),

                  _SnowfallLayer(
                    flakes: _snowflakes,
                    opacity: _starsOpacity.value,
                    animation: _snowfall,
                    size: size,
                  ),

                  if (_crawlProgress.value > 0)
                    _CrawlLayer(
                      progress: _crawlProgress.value,
                      title: 'about_hall_of_fame'.tr(),
                      names: _testers,
                      accent: accent,
                      size: size,
                    ),

                  IgnorePointer(
                    child: _Vignette(size: size),
                  ),

                  IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: _bgOpacity.value,
                      duration: const Duration(milliseconds: 1),
                      child: Container(color: Colors.black),
                    ),
                  ),

                  Positioned(
                    bottom: 48,
                    left: 0,
                    right: 0,
                    child: AnimatedOpacity(
                      opacity: _starsOpacity.value >= 0.7 ? 0.65 : 0.0,
                      duration: const Duration(milliseconds: 600),
                      child: Text(
                        'hall_of_fame_close_hint'.tr(),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.5),
                          letterSpacing: 2,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _StarField extends StatelessWidget {
  final List<_Star> stars;
  final double opacity;
  final AnimationController pulse;

  const _StarField({
    required this.stars,
    required this.opacity,
    required this.pulse,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, _) {
        final t = pulse.value;
        return CustomPaint(
          size: size,
          painter: _StarPainter(
            stars: stars,
            opacity: opacity,
            pulseT: t,
          ),
        );
      },
    );
  }
}

class _StarPainter extends CustomPainter {
  final List<_Star> stars;
  final double opacity;
  final double pulseT;

  _StarPainter({
    required this.stars,
    required this.opacity,
    required this.pulseT,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0) return;
    final paint = Paint()..style = PaintingStyle.fill;

    for (final s in stars) {
      final delay = s.delayMs / 1000.0;
      final cycle = ((pulseT + delay) % 1.0);
      final twinkle = 0.3 + 0.7 * (0.5 - 0.5 * cos(cycle * 2 * pi));
      final a = (s.opacity * twinkle * opacity).clamp(0.0, 1.0);
      if (a < 0.02) continue;

      paint.color = Colors.white.withValues(alpha: a);

      final cx = s.x * size.width;
      final cy = s.y * size.height;
      canvas.drawCircle(Offset(cx, cy), s.size * 0.5, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _StarPainter old) =>
      opacity != old.opacity || pulseT != old.pulseT;
}

class _SnowfallLayer extends StatelessWidget {
  final List<_Snowflake> flakes;
  final double opacity;
  final AnimationController animation;
  final Size size;

  const _SnowfallLayer({
    required this.flakes,
    required this.opacity,
    required this.animation,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = animation.value;
        return CustomPaint(
          size: size,
          painter: _SnowfallPainter(
            flakes: flakes,
            opacity: opacity,
            progress: t,
          ),
        );
      },
    );
  }
}

class _SnowfallPainter extends CustomPainter {
  final List<_Snowflake> flakes;
  final double opacity;
  final double progress;

  _SnowfallPainter({
    required this.flakes,
    required this.opacity,
    required this.progress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0) return;
    final paint = Paint()..style = PaintingStyle.fill;

    for (final f in flakes) {
      final y = ((f.initialY + progress * f.speed) % 1.15) - 0.15;
      if (y < -0.02 || y > 1.02) continue;

      final a = (f.opacity * opacity).clamp(0.0, 1.0);
      if (a < 0.02) continue;

      final screenY = y * size.height;
      final fade = (1.0 - (screenY / size.height)).clamp(0.0, 1.0);
      final effectiveAlpha = a * fade;

      paint.color = Colors.white.withValues(alpha: effectiveAlpha);
      canvas.drawCircle(
        Offset(f.x * size.width, screenY),
        f.size * 0.5,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SnowfallPainter old) =>
      opacity != old.opacity || progress != old.progress;
}

class _CrawlLayer extends StatelessWidget {
  final double progress;
  final String title;
  final List<String> names;
  final Color accent;
  final Size size;

  const _CrawlLayer({
    required this.progress,
    required this.title,
    required this.names,
    required this.accent,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final top = size.height * (1.0 - progress * 1.55);

    return ClipRect(
      child: Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.002)
          ..rotateX(0.62),
        child: Transform.translate(
          offset: Offset(0, top),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: size.width * 0.08),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    color: accent,
                    letterSpacing: 5,
                    shadows: [
                      Shadow(
                        color: accent.withValues(alpha: 0.35),
                        blurRadius: 18,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),
                ...names.map(
                  (name) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      name,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: accent.withValues(alpha: 0.9),
                        letterSpacing: 2,
                        shadows: [
                          Shadow(
                            color: accent.withValues(alpha: 0.25),
                            blurRadius: 12,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Vignette extends StatelessWidget {
  final Size size;
  const _Vignette({required this.size});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: size,
      painter: _VignettePainter(),
    );
  }
}

class _VignettePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final gradient = RadialGradient(
      center: Alignment.center,
      radius: 0.75,
      colors: [
        Colors.transparent,
        Colors.black.withValues(alpha: 0.85),
      ],
      stops: const [0.5, 1.0],
    );
    canvas.drawRect(rect, Paint()..shader = gradient.createShader(rect));
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
