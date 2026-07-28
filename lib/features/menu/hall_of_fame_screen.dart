import 'dart:math';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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

class HallOfFameScreen extends ConsumerStatefulWidget {
  const HallOfFameScreen({super.key});

  @override
  ConsumerState<HallOfFameScreen> createState() => _HallOfFameScreenState();
}

class _HallOfFameScreenState extends ConsumerState<HallOfFameScreen>
    with TickerProviderStateMixin, ShellHeaderMixin {
  late final AnimationController _master;
  late final Animation<double> _starsOpacity;
  late final AnimationController _starsPulse;
  late final AnimationController _crawl;

  @override
  int get headerBranchIndex => 3;

  bool _showHeaderForExit = false;

  @override
  ShellHeaderConfig buildShellHeader() =>
      ShellHeaderConfig(hidden: !_showHeaderForExit);

  final List<_Star> _starSeed = [];
  final List<String> _testers = [
    'nightsyr',
    'Саша Белый',
    'múrx',
    'lina',
    'ShikiN',
    'N K',
    'Сатаник1155',
  ];

  @override
  void initState() {
    super.initState();

    for (int i = 0; i < 240; i++) {
      _starSeed.add(
        _Star(
          x: _random.nextDouble(),
          y: _random.nextDouble(),
          size: 1.5 + _random.nextDouble() * 3.5,
          opacity: 0.35 + _random.nextDouble() * 0.65,
          twinkleMs: 1200 + _random.nextInt(2800),
          delayMs: (600 * _random.nextDouble()).round(),
        ),
      );
    }

    _master = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );

    _starsOpacity = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _master,
        curve: const Interval(0.25, 1.0, curve: Curves.easeOut),
      ),
    );

    _starsPulse = AnimationController(
      duration: const Duration(seconds: 3),
      vsync: this,
    )..repeat(reverse: true);

    _crawl = AnimationController(
      duration: const Duration(seconds: 120),
      vsync: this,
    )..repeat();

    _master.forward();
  }

  @override
  void reassemble() {
    super.reassemble();
    if (!_crawl.isAnimating) {
      _crawl.repeat();
    }
  }

  @override
  void dispose() {
    _master.dispose();
    _starsPulse.dispose();
    _crawl.dispose();
    super.dispose();
  }

  void _close() {
    _master.reverse().then((_) {
      if (mounted) {
        _showHeaderForExit = true;
        refreshShellHeader();
        context.go('/menu/about');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: AnimatedBuilder(
        animation: Listenable.merge([_master, _crawl]),
        builder: (context, child) {
          return Scaffold(
            backgroundColor: Colors.black,
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

                  if (_starsOpacity.value > 0)
                    Opacity(
                      opacity: _starsOpacity.value,
                      child: _CrawlLayer(
                        progress: _crawl.value,
                        title: 'about_hall_of_fame'.tr(),
                        names: _testers,
                        size: size,
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
          painter: _StarPainter(stars: stars, opacity: opacity, pulseT: t),
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

class _CrawlLayer extends StatelessWidget {
  final double progress;
  final String title;
  final List<String> names;
  final Size size;

  static const _yellowColor = Color(0xFFFFE81F);

  const _CrawlLayer({
    required this.progress,
    required this.title,
    required this.names,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final top = size.height * (0.85 - progress * 3.6);

    return ClipRect(
      child: Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.0018)
          ..rotateX(-0.68),
        child: Transform.translate(
          offset: Offset(0, top),
          child: OverflowBox(
            minHeight: 0,
            maxHeight: double.infinity,
            alignment: Alignment.topCenter,
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
                      color: _yellowColor,
                      letterSpacing: 5,
                      shadows: [
                        Shadow(
                          color: _yellowColor.withValues(alpha: 0.4),
                          blurRadius: 18,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 120),
                  ...names.map(
                    (name) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 70),
                      child: Text(
                        name,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: _yellowColor.withValues(alpha: 0.95),
                          letterSpacing: 2,
                          shadows: [
                            Shadow(
                              color: _yellowColor.withValues(alpha: 0.3),
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
      ),
    );
  }
}
