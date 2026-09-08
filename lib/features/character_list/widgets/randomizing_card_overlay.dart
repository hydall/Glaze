import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/models/character.dart';
import '../../../core/utils/html_to_markdown.dart';
import '../../../core/utils/platform_paths.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/card_tag_chips.dart';
import '../../../shared/widgets/colored_markdown.dart';
import '../../../shared/widgets/glaze_logo.dart';

/// Opens the randomizing character-discovery overlay.
///
/// A holographic "Holocard" (mirrors Glaze's `HoloCardViewer`) floats above the
/// character list on a dimmed, blurred backdrop. Swiping the card right (or
/// tapping the chat button) starts a brand-new chat with that character; swiping
/// left (or the skip button) discards it and deals the next random card. The
/// holographic tilt tracks the device gyroscope (or the mouse on desktop), not
/// the drag.
Future<void> showRandomizingCardOverlay(
  BuildContext context,
  List<Character> pool,
) {
  return showGeneralDialog<void>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    barrierColor: Colors.transparent,
    barrierLabel: 'randomizing_discovery',
    transitionDuration: const Duration(milliseconds: 340),
    pageBuilder: (_, _, _) => RandomizingCardOverlay(pool: pool),
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(opacity: curved, child: child);
    },
  );
}

class RandomizingCardOverlay extends StatefulWidget {
  final List<Character> pool;
  const RandomizingCardOverlay({super.key, required this.pool});

  @override
  State<RandomizingCardOverlay> createState() => _RandomizingCardOverlayState();
}

class _RandomizingCardOverlayState extends State<RandomizingCardOverlay>
    with TickerProviderStateMixin {
  /// Shuffled deck we deal from; reshuffled (endlessly) when exhausted.
  late List<Character> _deck;
  int _index = 0;

  /// Live drag offset of the top card, in logical pixels from its rest spot.
  Offset _drag = Offset.zero;
  bool _dragging = false;

  /// Set once a chat is being opened (right fling / chat button): hides the
  /// peeking next cards so nothing shows behind the card as it flies away.
  bool _openingChat = false;

  /// True while a card is flying off (fly-off, not spring-back). The action
  /// highlight (edge tint + button glow) is pinned to 0 while this is set so it
  /// fades out the instant the swipe commits, instead of tracking the drag
  /// offset — which balloons during the fly-off and would otherwise hold the
  /// highlight at full strength until the card lands.
  bool _flinging = false;

  /// Drives fly-off / spring-back of the top card by tweening [_drag].
  late final AnimationController _swipeCtrl;
  Animation<Offset>? _swipeTween;

  /// Drives the tap-to-flip (front ↔ back "рубашка" with the card's tabs).
  /// 0 = front, 1 = back.
  late final AnimationController _flipCtrl;
  bool _flipped = false;

  /// Endless idle shimmer that sweeps the holographic sheen at rest.
  late final AnimationController _shimmerCtrl;

  /// Entry pop of the whole stack.
  late final AnimationController _entryCtrl;

  /// Last direction we haptically "armed" so we buzz only on threshold crossings.
  int _armedDir = 0;

  // ─── Holographic tilt (gyroscope / mouse), smoothed into −1..1 ──────────────
  //
  // The sensor (or the mouse) writes a raw *target*; the actual [_tiltX]/[_tiltY]
  // used for rendering eases toward it once per frame (see [_onTiltFrame]).
  // Smoothing per-frame instead of per-sample keeps the motion fluid regardless
  // of the sensor's irregular delivery rate and filters out its jitter.
  double _tiltX = 0;
  double _tiltY = 0;
  double _targetTiltX = 0;
  double _targetTiltY = 0;

  /// Per-frame easing factor toward the target tilt. Lower = smoother but laggier.
  static const double _kTiltEase = 0.12;
  StreamSubscription<AccelerometerEvent>? _accelSub;

  /// Calibration reference captured on first sample after opening; the reading
  /// is expressed relative to it so the "flat" pose is wherever the phone was
  /// held. Slowly drifts back if the user tilts past [_kTiltLimit] (mirrors the
  /// Vue `HoloCardViewer` "catch-up" behaviour).
  double _calRoll = 0;
  double _calPitch = 0;
  bool _needsCalibration = true;
  static const double _kTiltLimit = 26; // degrees mapped to full ±1
  static const double _kDrift = 0.05;

  double get _screenW => MediaQuery.of(context).size.width;

  /// Guards the first (post-mount) preload pass so it runs only once.
  bool _preloadedOnce = false;

  /// Device-pixel width the deck's portraits are decoded to. Mirrors the card
  /// width computed in [build] (`min(screenW * 0.82, 350) * dpr`) so the value
  /// handed to [HoloCard.imageCacheWidth] and the one used by the preloader are
  /// identical — the swiped-in card then paints from an already-warm decode.
  int _imageCacheWidth() {
    final mq = MediaQuery.of(context);
    final cardW = math.min(mq.size.width * 0.82, 350.0);
    return (cardW * mq.devicePixelRatio).round();
  }

  /// Warms the image cache for the current card and the next couple in the deck
  /// so dealing the next card never blocks on a fresh full-resolution decode.
  ///
  /// Deferred to a post-frame callback so the (potentially heavy) full-res
  /// decodes never contend with the fly-off animation and re-freeze the swipe —
  /// the earlier version precached four images synchronously inside [_advance],
  /// saturating the decode/raster threads at the exact moment the next card
  /// needed to become responsive. Two ahead is enough: the top card is the
  /// previous peek (already warm) and the peek is warmed one deal early.
  void _precacheDeck() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final cacheW = _imageCacheWidth();
      const lookAhead = 2; // the upcoming peek + the one after it
      for (var k = 1; k <= lookAhead; k++) {
        final i = _index + k;
        if (i < 0 || i >= _deck.length) break;
        final provider = holoCardImageProvider(_deck[i], cacheW);
        if (provider != null) {
          // Swallow errors (missing/corrupt file) — the card falls back to its
          // placeholder on display anyway.
          precacheImage(provider, context, onError: (_, _) {});
        }
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_preloadedOnce) {
      _preloadedOnce = true;
      _precacheDeck();
    }
  }

  @override
  void initState() {
    super.initState();
    _deck = List<Character>.of(widget.pool)..shuffle();
    if (_deck.isEmpty) _deck = List<Character>.of(widget.pool);

    _swipeCtrl = AnimationController(
      vsync: this,
      // Snappy fly-off/spring-back: the next card's gestures stay blocked until
      // this finishes, so a shorter throw makes the deck feel immediately
      // responsive again after a swipe.
      duration: const Duration(milliseconds: 230),
    )..addListener(_onSwipeTick);

    _shimmerCtrl =
        AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: 3600),
          )
          // Doubles as the per-frame clock that eases the tilt toward its target.
          ..addListener(_onTiltFrame)
          ..repeat();

    _entryCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    )..forward();

    _flipCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );

    // Drive the holographic tilt from the device gyroscope. On platforms with
    // no accelerometer (most desktops / web) the stream simply errors out and
    // the mouse fallback (see [_onHoverTilt]) takes over instead.
    try {
      _accelSub = accelerometerEventStream(
        samplingPeriod: SensorInterval.gameInterval,
      ).listen(_onAccelerometer, onError: (_) {});
    } catch (_) {
      _accelSub = null;
    }
  }

  @override
  void dispose() {
    _accelSub?.cancel();
    _swipeCtrl.dispose();
    _shimmerCtrl.dispose();
    _entryCtrl.dispose();
    _flipCtrl.dispose();
    super.dispose();
  }

  /// Converts the gravity vector into roll/pitch angles, re-bases them against
  /// the calibration pose (with slow drift), clamps to ±[_kTiltLimit] and
  /// smooths the normalised result into [_tiltX]/[_tiltY]. Runs off-frame; the
  /// per-frame shimmer rebuild renders whatever value is current.
  void _onAccelerometer(AccelerometerEvent e) {
    final rollDeg =
        math.atan2(e.x, math.sqrt(e.y * e.y + e.z * e.z)) * 180 / math.pi;
    final pitchDeg =
        math.atan2(e.y, math.sqrt(e.x * e.x + e.z * e.z)) * 180 / math.pi;

    if (_needsCalibration) {
      _calRoll = rollDeg;
      _calPitch = pitchDeg;
      _needsCalibration = false;
    }

    // Catch-up drift so the neutral pose follows the phone if it's held tilted.
    final rawR = rollDeg - _calRoll;
    if (rawR > _kTiltLimit) {
      _calRoll += (rawR - _kTiltLimit) * _kDrift;
    } else if (rawR < -_kTiltLimit) {
      _calRoll += (rawR + _kTiltLimit) * _kDrift;
    }
    final rawP = pitchDeg - _calPitch;
    if (rawP > _kTiltLimit) {
      _calPitch += (rawP - _kTiltLimit) * _kDrift;
    } else if (rawP < -_kTiltLimit) {
      _calPitch += (rawP + _kTiltLimit) * _kDrift;
    }

    final tx = ((rollDeg - _calRoll) / _kTiltLimit).clamp(-1.0, 1.0);
    final ty = ((pitchDeg - _calPitch) / _kTiltLimit).clamp(-1.0, 1.0);
    // Only record the target; [_onTiltFrame] eases the rendered value toward it
    // once per frame so the foil glides instead of snapping on each sample.
    _targetTiltX = tx.toDouble();
    _targetTiltY = -ty.toDouble();
  }

  /// Eases the rendered tilt toward the latest target. Runs every shimmer frame
  /// (~60fps), just before the deck's [AnimatedBuilder] reads [_tiltX]/[_tiltY].
  void _onTiltFrame() {
    _tiltX += (_targetTiltX - _tiltX) * _kTiltEase;
    _tiltY += (_targetTiltY - _tiltY) * _kTiltEase;
  }

  /// Desktop / web fallback: tilt tracks the pointer over the card.
  void _onHoverTilt(Offset local, Size size) {
    if (size.width == 0 || size.height == 0) return;
    final tx = (local.dx / size.width * 2 - 1).clamp(-1.0, 1.0);
    final ty = (local.dy / size.height * 2 - 1).clamp(-1.0, 1.0);
    _targetTiltX = tx.toDouble();
    _targetTiltY = ty.toDouble();
  }

  void _onHoverExit() {
    _targetTiltX = 0;
    _targetTiltY = 0;
  }

  void _onSwipeTick() {
    final t = _swipeTween;
    if (t != null) setState(() => _drag = t.value);
  }

  Character? get _current =>
      (_index >= 0 && _index < _deck.length) ? _deck[_index] : null;

  Character? get _next =>
      (_index + 1 < _deck.length) ? _deck[_index + 1] : null;

  // ─── Gesture handling ──────────────────────────────────────────────────────

  void _onPanStart(DragStartDetails _) {
    if (_swipeCtrl.isAnimating || _flipCtrl.isAnimating || _flipped) return;
    setState(() => _dragging = true);
  }

  /// Tap the card to flip it to its back (the card's tabs) and tap again to
  /// flip back. Ignored mid-swipe so a fling isn't interrupted.
  void _toggleFlip() {
    if (_flipCtrl.isAnimating || _swipeCtrl.isAnimating || _dragging) return;
    setState(() => _flipped = !_flipped);
    if (_flipped) {
      _flipCtrl.forward();
    } else {
      _flipCtrl.reverse();
    }
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (!_dragging) return;
    setState(() => _drag += d.delta);
    final dir = _drag.dx > _threshold
        ? 1
        : _drag.dx < -_threshold
        ? -1
        : 0;
    if (dir != _armedDir) {
      _armedDir = dir;
      if (dir != 0) HapticFeedback.selectionClick();
    }
  }

  double get _threshold => (_screenW * 0.28).clamp(70.0, 160.0);

  void _onPanEnd(DragEndDetails d) {
    _dragging = false;
    final vx = d.velocity.pixelsPerSecond.dx;
    final decideRight = _drag.dx > _threshold || vx > 900;
    final decideLeft = _drag.dx < -_threshold || vx < -900;
    if (decideRight) {
      _flyOff(1);
    } else if (decideLeft) {
      _flyOff(-1);
    } else {
      _springBack();
    }
  }

  void _springBack() {
    _armedDir = 0;
    _swipeTween = Tween<Offset>(
      begin: _drag,
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _swipeCtrl, curve: Curves.easeOutBack));
    _swipeCtrl
      ..reset()
      ..forward();
  }

  void _flyOff(int dir) {
    final card = _current;
    if (card == null) return;
    _armedDir = 0;
    // Drop the action highlight immediately: the drag offset balloons as the
    // card flies off, so without this the tint/glow would stay pinned at full
    // until the card lands. The swipe controller's first tick rebuilds with this
    // set, easing the highlight out over its own short fade.
    _flinging = true;
    // A flipped card flies off as its front, not its back.
    if (_flipped) {
      _flipped = false;
      _flipCtrl.value = 0;
    }
    // Opening a chat: hide the deck behind the fly-off (the next tick's setState
    // from the swipe controller applies it).
    if (dir > 0) _openingChat = true;
    HapticFeedback.mediumImpact();
    final target = Offset(
      dir * (_screenW + 240),
      _drag.dy + (_drag.dy.abs() < 20 ? -40 : _drag.dy * 0.6),
    );
    _swipeTween = Tween<Offset>(
      begin: _drag,
      end: target,
    ).animate(CurvedAnimation(parent: _swipeCtrl, curve: Curves.easeOutCubic));
    _swipeCtrl
      ..reset()
      ..forward().whenCompleteOrCancel(() {
        if (!mounted) return;
        if (dir > 0) {
          _startChat(card);
        } else {
          _advance();
        }
      });
  }

  void _advance() {
    setState(() {
      _drag = Offset.zero;
      _flinging = false;
      // The next card always starts front-side up.
      _flipped = false;
      _flipCtrl.value = 0;
      _index++;
      if (_index >= _deck.length) {
        // Endless discovery: reshuffle and keep dealing, avoiding an immediate
        // repeat of the card that was just on top.
        final last = _deck.isNotEmpty ? _deck.last : null;
        _deck = List<Character>.of(widget.pool)..shuffle();
        if (_deck.length > 1 && _deck.first.id == last?.id) {
          _deck.add(_deck.removeAt(0));
        }
        _index = 0;
      }
    });
    // Warm the newly-exposed cards so the next deal stays smooth.
    _precacheDeck();
  }

  void _startChat(Character c) {
    // Capture the router before popping — this widget's context is torn down by
    // the pop, but the app-level router stays valid.
    final router = GoRouter.of(context);
    Navigator.of(context, rootNavigator: true).pop();
    router.go('/chat/${c.id}?new=1');
  }

  void _close() {
    Navigator.of(context, rootNavigator: true).pop();
  }

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final cardW = math.min(size.width * 0.82, 350.0);
    final cardH = math.min(cardW * 1.5, size.height * 0.62);
    final progress = (_drag.dx / _threshold).clamp(-1.0, 1.0).toDouble();
    // The action highlight follows the live drag, but snaps to 0 the moment a
    // fly-off commits so it fades out immediately instead of riding the card's
    // (huge) fly-off offset. The card visuals below still use the raw [progress].
    final highlightProgress = _flinging ? 0.0 : progress;

    // A transparent Material provides the ambient DefaultTextStyle the overlay
    // sits on. `showGeneralDialog` doesn't insert one, so without it every Text
    // inherits the framework's "missing style" debug paint (the yellow
    // double-underline) instead of the app's Inter theme text.
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          // Dimmed, blurred backdrop over the character list. Isolated in its own
          // AnimatedBuilder so it only repaints during the entry fade — not on
          // every idle-shimmer frame (a per-frame blur recompute would be janky).
          Positioned.fill(
            child: GestureDetector(
              onTap: _close,
              child: AnimatedBuilder(
                animation: _entryCtrl,
                builder: (context, _) {
                  final t = Curves.easeOut.transform(_entryCtrl.value);
                  return BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 14 * t, sigmaY: 14 * t),
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.72 * t),
                    ),
                  );
                },
              ),
            ),
          ),
          // Directional tint: as the card is dragged toward an action, half the
          // screen washes into that button's colour (green-ish primary for chat,
          // red for skip).
          Positioned.fill(
            child: IgnorePointer(
              child: _EdgeTint(
                progress: highlightProgress,
                chatColor: context.cs.primary,
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                _TopBar(onClose: _close),
                Expanded(
                  child: Center(
                    child: SizedBox(
                      width: cardW,
                      height: cardH,
                      // Only the deck rebuilds per shimmer/swipe/flip frame.
                      child: AnimatedBuilder(
                        animation: Listenable.merge([
                          _shimmerCtrl,
                          _swipeCtrl,
                          _flipCtrl,
                        ]),
                        builder: (context, _) => _buildDeck(
                          cardW,
                          cardH,
                          (_drag.dx / _threshold).clamp(-1.0, 1.0).toDouble(),
                          Curves.easeOut.transform(_entryCtrl.value),
                        ),
                      ),
                    ),
                  ),
                ),
                _ActionBar(
                  progress: highlightProgress,
                  onSkip: () {
                    if (_current != null && !_swipeCtrl.isAnimating) {
                      _drag = const Offset(-30, 0);
                      _flyOff(-1);
                    }
                  },
                  onChat: () {
                    if (_current != null && !_swipeCtrl.isAnimating) {
                      _drag = const Offset(30, 0);
                      _flyOff(1);
                    }
                  },
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    'randomizing_hint'.tr(),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeck(double cardW, double cardH, double progress, double entry) {
    final current = _current;
    if (current == null) {
      return _EmptyDeck(onClose: _close);
    }

    final absProgress = progress.abs();
    final cacheW = _imageCacheWidth();

    final children = <Widget>[];

    // Peek of the next card, growing toward full size as the top card leaves.
    final next = _next;
    if (next != null) {
      final peekScale = 0.9 + 0.1 * absProgress;
      final peekOpacity = 0.55 + 0.45 * absProgress;
      // When a chat is opening, fade the deck out smoothly — in step with the
      // top card's fly-off (driven by the swipe controller) — instead of
      // popping it away. `_swipeCtrl` runs 0→1 over the fling, so the peek
      // dissolves as the card leaves.
      final openingFade = _openingChat
          ? (1.0 - _swipeCtrl.value).clamp(0.0, 1.0)
          : 1.0;
      children.add(
        Center(
          child: Opacity(
            opacity: (peekOpacity * openingFade).clamp(0.0, 1.0),
            child: Transform.scale(
              scale: peekScale,
              child: RepaintBoundary(
                child: HoloCard(
                  key: ValueKey('peek_${next.id}'),
                  character: next,
                  tiltX: 0,
                  tiltY: 0,
                  width: cardW,
                  height: cardH,
                  imageCacheWidth: cacheW,
                ),
              ),
            ),
          ),
        ),
      );
    }

    // The active top card. The drag only translates/swings it (swipe-to-fling
    // fling); the holographic tilt of the foil comes from the gyroscope (or the
    // mouse on desktop) via [_tiltX]/[_tiltY].
    final swing = (_drag.dx / _screenW) * 0.32;
    // Subtle entry pop for the top card.
    final entryScale = 0.86 + 0.14 * entry;

    // Tap-to-flip: rotate the card about Y on an ease-in-out curve (a linear
    // spin read stiff/"колхозно"). Past the halfway point the back ("рубашка",
    // the card's tabs) shows, counter-rotated so it reads normally.
    final flipT = Curves.easeInOutCubic.transform(_flipCtrl.value);
    final showBack = flipT >= 0.5;

    final Widget face;
    if (!showBack) {
      face = MouseRegion(
        onHover: (e) => _onHoverTilt(e.localPosition, Size(cardW, cardH)),
        onExit: (_) => _onHoverExit(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleFlip,
          onPanStart: _onPanStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          child: RepaintBoundary(
            child: HoloCard(
              key: ValueKey('top_${current.id}'),
              character: current,
              tiltX: _tiltX,
              tiltY: _tiltY,
              width: cardW,
              height: cardH,
              imageCacheWidth: cacheW,
            ),
          ),
        ),
      );
    } else {
      face = Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()..rotateY(math.pi),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleFlip,
          child: RepaintBoundary(
            child: _CardBack(
              key: ValueKey('back_${current.id}'),
              character: current,
              accent: _accentFor(current),
            ),
          ),
        ),
      );
    }

    children.add(
      Center(
        child: Transform.translate(
          offset: _drag,
          child: Transform.rotate(
            angle: swing,
            child: Transform.scale(
              scale: _dragging || _swipeCtrl.isAnimating ? 1.0 : entryScale,
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.001)
                  ..rotateY(flipT * math.pi),
                child: SizedBox(width: cardW, height: cardH, child: face),
              ),
            ),
          ),
        ),
      ),
    );

    // `Clip.none` so the top card's unclipped print layer (frame/name/badge)
    // can float a few px past the card edge as it parallaxes.
    return Stack(clipBehavior: Clip.none, children: children);
  }

  /// Accent colour for [c] (its stored colour, else the default), used to theme
  /// the card back until/without image-derived colour.
  Color _accentFor(Character c) {
    final col = c.color;
    if (col != null) {
      try {
        return Color(int.parse('FF${col.replaceFirst('#', '')}', radix: 16));
      } catch (_) {}
    }
    return const Color(0xFF7996CE);
  }
}

// ─── Top bar ───────────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final VoidCallback onClose;
  const _TopBar({required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          const Spacer(),
          _RoundButton(
            icon: Icons.close_rounded,
            size: 44,
            iconSize: 22,
            background: Colors.black.withValues(alpha: 0.5),
            iconColor: Colors.white,
            onTap: onClose,
          ),
        ],
      ),
    );
  }
}

// ─── Action bar ──────────────────────────────────────────────────────────────

class _ActionBar extends StatelessWidget {
  final double progress;
  final VoidCallback onSkip;
  final VoidCallback onChat;
  const _ActionBar({
    required this.progress,
    required this.onSkip,
    required this.onChat,
  });

  @override
  Widget build(BuildContext context) {
    const skipColor = Color(0xFFFF5A6E);
    final chatColor = context.cs.primary;

    // Ease the button growth toward the current drag progress. Because the raw
    // progress snaps back to 0 in a single frame when a card flies off, tweening
    // it keeps the buttons from shrinking "за кадр".
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: progress.clamp(-1.0, 1.0)),
      duration: const Duration(milliseconds: 130),
      curve: Curves.easeOut,
      builder: (context, p, _) {
        final skipScale = 1.0 + (p < 0 ? -p * 0.18 : 0.0);
        final chatScale = 1.0 + (p > 0 ? p * 0.18 : 0.0);
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Transform.scale(
              scale: skipScale,
              child: _RoundButton(
                icon: Icons.close_rounded,
                size: 78,
                iconSize: 38,
                background: const Color(0xFF1C1C22),
                iconColor: skipColor,
                border: Border.all(
                  color: skipColor.withValues(alpha: 0.6),
                  width: 2,
                ),
                glow: skipColor.withValues(
                  alpha: (0.3 + (skipScale - 1.0)).clamp(0.0, 1.0),
                ),
                onTap: onSkip,
              ),
            ),
            const SizedBox(width: 52),
            Transform.scale(
              scale: chatScale,
              child: _RoundButton(
                icon: Icons.chat_bubble_rounded,
                size: 78,
                iconSize: 34,
                background: const Color(0xFF1C1C22),
                iconColor: chatColor,
                border: Border.all(
                  color: chatColor.withValues(alpha: 0.6),
                  width: 2,
                ),
                glow: chatColor.withValues(
                  alpha: (0.35 + (chatScale - 1.0)).clamp(0.0, 1.0),
                ),
                onTap: onChat,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final double iconSize;
  final Color background;
  final Color iconColor;
  final BoxBorder? border;
  final Color? glow;
  final VoidCallback onTap;

  const _RoundButton({
    required this.icon,
    required this.size,
    required this.iconSize,
    required this.background,
    required this.iconColor,
    required this.onTap,
    this.border,
    this.glow,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: background,
          shape: BoxShape.circle,
          border: border,
          boxShadow: [
            if (glow != null)
              BoxShadow(color: glow!, blurRadius: 22, spreadRadius: 1),
            const BoxShadow(
              color: Color(0x66000000),
              blurRadius: 12,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Icon(icon, size: iconSize, color: iconColor),
      ),
    );
  }
}

class _EmptyDeck extends StatelessWidget {
  final VoidCallback onClose;
  const _EmptyDeck({required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.style_outlined, size: 48, color: Colors.white38),
          const SizedBox(height: 16),
          Text(
            'randomizing_empty'.tr(),
            style: const TextStyle(color: Colors.white70, fontSize: 15),
          ),
          const SizedBox(height: 20),
          TextButton(onPressed: onClose, child: Text('btn_close'.tr())),
        ],
      ),
    );
  }
}

// ─── Holographic card ────────────────────────────────────────────────────────

/// Full-resolution avatar provider for the discovery card, decoded down to
/// [cacheWidth] device pixels (preserving aspect) so the big card renders from
/// the crisp source PNG instead of the small square list thumbnail — without
/// paying a full multi-megabyte decode. Returns null when the card has no
/// avatar. Reused verbatim by the overlay's background preloader so the
/// precached decode and the displayed decode share one image-cache key.
ImageProvider? holoCardImageProvider(Character character, int cacheWidth) {
  final path = resolveGlazeFilePath(character.avatarPath);
  if (path == null || path.isEmpty) return null;
  final file = FileImage(File(path));
  if (cacheWidth <= 0) return file;
  return ResizeImage(file, width: cacheWidth, allowUpscaling: false);
}

/// A holographic character card mirroring Glaze's `HoloCardViewer`: a parallax
/// portrait under a diagonal rainbow-foil band, a white sheen and a centred
/// glare — all driven purely by the device tilt, with no idle animation (the
/// Vue original uses `transition: none` and only moves on input). [tiltX]/
/// [tiltY] (−1..1) drive the 3D tilt, the band position and the glare opacity.
class HoloCard extends StatelessWidget {
  final Character character;
  final double tiltX;
  final double tiltY;
  final double width;
  final double height;

  /// Device-pixel width the full-resolution portrait is decoded down to. Kept
  /// in sync with the overlay's preloader (same value → same image-cache key)
  /// so a swiped-in card paints from an already-warm decode.
  final int imageCacheWidth;

  const HoloCard({
    super.key,
    required this.character,
    required this.tiltX,
    required this.tiltY,
    required this.width,
    required this.height,
    this.imageCacheWidth = 0,
  });

  String get _displayName {
    final dn = character.displayName?.trim();
    return (dn != null && dn.isNotEmpty) ? dn : character.name;
  }

  /// Short blurb shown under the name — the creator's notes when present (the
  /// user-facing tagline), falling back to the character description.
  String? get _shortDescription {
    final notes = character.creatorNotes?.trim();
    if (notes != null && notes.isNotEmpty) return notes;
    final desc = character.description?.trim();
    if (desc != null && desc.isNotEmpty) return desc;
    return null;
  }

  Color get _avatarColor {
    final c = character.color;
    if (c != null) {
      try {
        return Color(int.parse('FF${c.replaceFirst('#', '')}', radix: 16));
      } catch (_) {}
    }
    return const Color(0xFF7996CE);
  }

  /// Resolved portrait path (thumbnail preferred — smaller/faster to decode for
  /// the palette extraction), or null when the card has no avatar.
  String? get _imagePath =>
      resolveGlazeThumbnailPath(character.avatarPath) ??
      resolveGlazeFilePath(character.avatarPath);

  @override
  Widget build(BuildContext context) {
    // Purely tilt-driven — no idle animation (that constant sweep was the
    // "jelly" wobble). `pos` (0..1) is where the diagonal light band sits, moved
    // by the left/right tilt only, mirroring the Vue `sheenPos = 50 + xNorm*40`.
    // The glare fades in with the tilt magnitude (`min(1, |x| + |y|*0.5)`).
    final pos = (0.5 + tiltX * 0.34).clamp(0.16, 0.84).toDouble();
    final glareMag = math.min(1.0, tiltX.abs() + tiltY.abs() * 0.5).toDouble();

    // Clipped visual layers only: the portrait and the holographic foil / sheen
    // / glare must fill the rounded card edge-to-edge and never spill, so they
    // stay inside this ClipRRect + the casing clip below.
    final clipped = ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1 — Parallax portrait. The overscan gives the parallax shift room to
          // move without exposing the card edge; everything stays clipped below.
          Transform.scale(
            scale: 1.12,
            child: Transform.translate(
              offset: Offset(tiltX * 6, tiltY * 6),
              child: _buildImage(),
            ),
          ),

          // 2 — Rainbow foil, masked to the moving diagonal band so the colour
          // is only ever visible inside the light streak (color-dodge). The band
          // slides along the diagonal as the card is tilted left/right.
          _BlendMask(
            blendMode: BlendMode.colorDodge,
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (rect) => _bandGradient(
                pos,
                const Color(0xFFFFFFFF),
              ).createShader(rect),
              child: const _RainbowFoil(),
            ),
          ),

          // 3 — The white light band itself (screen/plus).
          _BlendMask(
            blendMode: BlendMode.plus,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: _bandGradient(pos, const Color(0x40FFFFFF)),
              ),
            ),
          ),

          // 4 — Bottom legibility gradient.
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 200,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  stops: [0.0, 0.55, 1.0],
                  colors: [
                    Color(0xF2000000),
                    Color(0x99000000),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),

          // 5 — Centred round glare; only its opacity tracks the tilt magnitude,
          // so it reads as a highlight that appears as the card turns to the
          // light (matching the Vue glare fixed at 50% 50%).
          _BlendMask(
            blendMode: BlendMode.plus,
            child: _Glare(opacity: glareMag),
          ),
        ],
      ),
    );

    // The framed physical card (rounded casing + the clipped content).
    final casing = Container(
      padding: const EdgeInsets.all(4),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0x26FFFFFF), Color(0x05FFFFFF), Color(0x1AFFFFFF)],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.55),
            blurRadius: 40,
            offset: const Offset(0, 22),
          ),
          BoxShadow(
            color: _avatarColor.withValues(alpha: 0.25),
            blurRadius: 30,
            spreadRadius: -6,
          ),
        ],
      ),
      child: clipped,
    );

    // Outer casing + the unclipped "print" layer (frame / name / tags / badge),
    // all under one 3D tilt. The print layer lives OUTSIDE the clip (Stack
    // `Clip.none`) so, as it counter-parallaxes, it can float a few px past the
    // card edge over the dimmed backdrop instead of being sliced off.
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.0011)
        ..rotateX(tiltY * 0.11)
        ..rotateY(tiltX * 0.11),
      child: Stack(
        clipBehavior: Clip.none,
        fit: StackFit.expand,
        children: [
          casing,

          // Inner border frame (inset 14 = 4 casing + 10), parallaxed.
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: IgnorePointer(
                child: Transform.translate(
                  offset: Offset(tiltX * 12, tiltY * 12),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.35),
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Name / creator / short description, parallaxed.
          Positioned(
            left: 24,
            right: 24,
            bottom: 26,
            child: Transform.translate(
              offset: Offset(tiltX * 12, tiltY * 12),
              child: _CardInfo(
                name: _displayName,
                creator: character.creator,
                description: _shortDescription,
              ),
            ),
          ),

          // Tags in the top-left corner, colour-coded like the list cards.
          if (character.tags.isNotEmpty)
            Positioned(
              top: 22,
              left: 22,
              right: 72, // clear the badge
              child: Transform.translate(
                offset: Offset(tiltX * 10, tiltY * 10),
                child: IgnorePointer(
                  child: CardTagChips(tags: character.tags, max: 3),
                ),
              ),
            ),

          // Top badge: the filled Glaze logo, tinted with the card's accent.
          Positioned(
            top: 22,
            right: 22,
            child: Transform.translate(
              offset: Offset(tiltX * 12, tiltY * 12),
              child: _TopBadge(imagePath: _imagePath, fallback: _avatarColor),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImage() {
    // Render the full-resolution avatar (decoded down to the card's on-screen
    // size via [imageCacheWidth]) so this large focal card stays crisp instead
    // of upscaling the tiny square list thumbnail. The decode cost that used to
    // make dealing the next card hitch is hidden by the overlay's background
    // preloader, which warms this exact provider a few cards ahead; a card that
    // still needs a fresh decode fades in via [frameBuilder] instead of popping.
    final provider = holoCardImageProvider(character, imageCacheWidth);
    if (provider == null) return _placeholder();
    return Image(
      image: provider,
      fit: BoxFit.cover,
      alignment: Alignment.topCenter,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) return child;
        return AnimatedOpacity(
          opacity: frame == null ? 0 : 1,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          child: child,
        );
      },
      errorBuilder: (_, _, _) => _placeholder(),
    );
  }

  Widget _placeholder() {
    return Container(
      color: _avatarColor.withValues(alpha: 0.25),
      child: Center(
        child: Text(
          _displayName.isNotEmpty ? _displayName[0].toUpperCase() : '?',
          style: TextStyle(
            fontSize: 96,
            fontWeight: FontWeight.w800,
            color: _avatarColor.withValues(alpha: 0.9),
          ),
        ),
      ),
    );
  }
}

// ─── Holographic sub-layers ──────────────────────────────────────────────────

/// Composites [child] against the layers beneath it using [blendMode]
/// (Flutter's `Stack` normally paints children with `srcOver` only).
class _BlendMask extends SingleChildRenderObjectWidget {
  final BlendMode blendMode;
  const _BlendMask({required this.blendMode, required Widget super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderBlendMask(blendMode);

  @override
  void updateRenderObject(BuildContext context, _RenderBlendMask ro) {
    ro.blendMode = blendMode;
  }
}

class _RenderBlendMask extends RenderProxyBox {
  _RenderBlendMask(this._blendMode);
  BlendMode _blendMode;
  set blendMode(BlendMode v) {
    if (v == _blendMode) return;
    _blendMode = v;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    context.canvas.saveLayer(offset & size, Paint()..blendMode = _blendMode);
    super.paint(context, offset);
    context.canvas.restore();
  }
}

class _RainbowFoil extends StatelessWidget {
  const _RainbowFoil();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment(-1.4, -1),
          end: Alignment(1.4, 1),
          colors: [
            Color(0x00000000),
            Color(0x33FF3B6B),
            Color(0x33FFD23B),
            Color(0x333BFF9E),
            Color(0x333BC8FF),
            Color(0x33B23BFF),
            Color(0x00000000),
          ],
          stops: [0.0, 0.18, 0.34, 0.5, 0.66, 0.82, 1.0],
        ),
      ),
    );
  }
}

/// A soft diagonal light band centred at [pos] (0..1) along the card diagonal,
/// filled with [color] and fading to fully transparent on both sides (using the
/// same hue at 0 alpha so the fade stays neutral). Used both as the rainbow-foil
/// mask and, filled with translucent white, as the sheen itself.
LinearGradient _bandGradient(double pos, Color color) {
  final c = pos.clamp(0.16, 0.84);
  final edge = color.withValues(alpha: 0);
  return LinearGradient(
    begin: const Alignment(-1, -0.7),
    end: const Alignment(1, 0.7),
    colors: [edge, edge, color, edge, edge],
    stops: [0.0, c - 0.16, c, c + 0.16, 1.0],
  );
}

class _Glare extends StatelessWidget {
  final double opacity;
  const _Glare({required this.opacity});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity.clamp(0.0, 1.0),
      child: const DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 0.75,
            colors: [Color(0xCCFFFFFF), Color(0x33FFFFFF), Color(0x00FFFFFF)],
            stops: [0.0, 0.2, 0.6],
          ),
        ),
      ),
    );
  }
}

/// Directional wash shown while the top card is dragged toward an action: the
/// half of the screen the card is heading to fills with that button's colour,
/// its strength tracking the drag [progress] (−1 = full skip, +1 = full chat).
class _EdgeTint extends StatelessWidget {
  final double progress;
  final Color chatColor;
  const _EdgeTint({required this.progress, required this.chatColor});

  @override
  Widget build(BuildContext context) {
    // Ease toward the current progress so the wash fades in/out smoothly rather
    // than snapping off the instant a card flies away and the drag resets.
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: progress.clamp(-1.0, 1.0)),
      duration: const Duration(milliseconds: 130),
      curve: Curves.easeOut,
      builder: (context, p, _) {
        if (p.abs() < 0.001) return const SizedBox.shrink();
        final right = p > 0;
        final color = right ? chatColor : const Color(0xFFFF5A6E);
        final strength = p.abs();
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: right ? Alignment.centerRight : Alignment.centerLeft,
              end: Alignment.center,
              colors: [
                color.withValues(alpha: 0.5 * strength),
                color.withValues(alpha: 0),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The corner logo, tinted with the accent colour pulled from *this card's*
/// portrait (vibrant → dominant), so every card lights the badge in its own
/// hue. Falls back to [fallback] until the palette resolves (or when the card
/// has no image). Extraction runs once per mount; the enclosing [HoloCard] is
/// keyed by character id, so switching cards re-extracts for the new portrait.
class _TopBadge extends StatefulWidget {
  final String? imagePath;
  final Color fallback;
  const _TopBadge({required this.imagePath, required this.fallback});

  @override
  State<_TopBadge> createState() => _TopBadgeState();
}

class _TopBadgeState extends State<_TopBadge> {
  Color? _accent;

  @override
  void initState() {
    super.initState();
    // Deferred a frame: PaletteGenerator quantizes on the main isolate, so
    // running it inline as a freshly-dealt card mounts adds a hitch right when
    // the swipe needs to stay smooth. The badge shows its fallback tint until
    // then (a frame later), which is imperceptible.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _extractAccent();
    });
  }

  Future<void> _extractAccent() async {
    final path = widget.imagePath;
    if (path == null) return;
    try {
      final palette = await PaletteGenerator.fromImageProvider(
        // Downscale first: the palette doesn't need full resolution and a small
        // image keeps extraction to a few milliseconds.
        ResizeImage(FileImage(File(path)), width: 96, height: 144),
        maximumColorCount: 12,
      );
      final color =
          palette.vibrantColor?.color ??
          palette.lightVibrantColor?.color ??
          palette.dominantColor?.color;
      if (mounted && color != null) setState(() => _accent = color);
    } catch (_) {
      // Keep the fallback tint.
    }
  }

  @override
  Widget build(BuildContext context) {
    // Lift the accent toward white a touch so it stays legible on the dark
    // badge even for very dark portraits.
    final tint = Color.lerp(_accent ?? widget.fallback, Colors.white, 0.25)!;
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.4),
          width: 2,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 8,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(9),
        child: SvgPicture.string(
          glazeFilledLogoSvg,
          fit: BoxFit.contain,
          colorFilter: ColorFilter.mode(tint, BlendMode.srcIn),
        ),
      ),
    );
  }
}

class _CardInfo extends StatelessWidget {
  final String name;
  final String? creator;
  final String? description;
  const _CardInfo({required this.name, this.creator, this.description});

  @override
  Widget build(BuildContext context) {
    final desc = description?.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Metallic gradient name, uppercase, à la Holocard.
        ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFFFFFFFF),
              Color(0xFFDADADA),
              Color(0xFFFFFFFF),
              Color(0xFFCFCFCF),
            ],
            stops: [0.0, 0.35, 0.65, 1.0],
          ).createShader(bounds),
          child: Text(
            name.toUpperCase(),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 27,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.2,
              height: 1.05,
              color: Colors.white,
              shadows: [Shadow(blurRadius: 6, color: Color(0xCC000000))],
            ),
          ),
        ),
        if (creator != null && creator!.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            '@${creator!}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: 0.7),
              shadows: const [Shadow(blurRadius: 4, color: Colors.black87)],
            ),
          ),
        ],
        if (desc != null && desc.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            desc,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              height: 1.3,
              color: Colors.white.withValues(alpha: 0.82),
              shadows: const [Shadow(blurRadius: 4, color: Colors.black87)],
            ),
          ),
        ],
      ],
    );
  }
}

// ─── Card back ("рубашка") ───────────────────────────────────────────────────

/// The flip side of the card: the same two tabs the detail sheet shows — Info
/// (tags + description) and Prompt Blocks (the character's prompt fields). Dark
/// "back of the card" surface, tinted with the card's accent.
class _CardBack extends StatefulWidget {
  final Character character;
  final Color accent;
  const _CardBack({super.key, required this.character, required this.accent});

  @override
  State<_CardBack> createState() => _CardBackState();
}

class _CardBackState extends State<_CardBack> {
  int _tab = 0; // 0 = info, 1 = prompts

  /// Per-section expand state for the Prompt Blocks accordions.
  final Map<int, bool> _expanded = {};

  Character get _c => widget.character;

  String get _displayName {
    final dn = _c.displayName?.trim();
    return (dn != null && dn.isNotEmpty) ? dn : _c.name;
  }

  /// The character's prompt fields, mirroring the detail sheet's Prompt Blocks
  /// tab, dropping any that are empty.
  List<({String label, String text})> get _promptSections {
    final list = <({String label, String text})>[
      (label: 'label_description'.tr(), text: _c.description ?? ''),
      (label: 'label_personality'.tr(), text: _c.personality ?? ''),
      (label: 'label_scenario'.tr(), text: _c.scenario ?? ''),
      (label: 'label_mes_example'.tr(), text: _c.mesExample ?? ''),
      (label: 'role_system'.tr(), text: _c.systemPrompt ?? ''),
      (label: 'role_system'.tr(), text: _c.postHistoryInstructions ?? ''),
      (label: 'label_first_mes'.tr(), text: _c.firstMes ?? ''),
    ];
    for (var i = 0; i < _c.alternateGreetings.length; i++) {
      list.add((
        label: '${'placeholder_greeting'.tr()} ${i + 2}',
        text: _c.alternateGreetings[i],
      ));
    }
    return list.where((s) => s.text.trim().isNotEmpty).toList();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Color.lerp(widget.accent, Colors.white, 0.18)!;
    return Container(
      // Same casing as the front so the flip reads as one physical card.
      padding: const EdgeInsets.all(4),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0x26FFFFFF), Color(0x05FFFFFF), Color(0x1AFFFFFF)],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.55),
            blurRadius: 40,
            offset: const Offset(0, 22),
          ),
          BoxShadow(
            color: widget.accent.withValues(alpha: 0.25),
            blurRadius: 30,
            spreadRadius: -6,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color.alphaBlend(
                  widget.accent.withValues(alpha: 0.16),
                  const Color(0xFF16161C),
                ),
                const Color(0xFF111116),
              ],
            ),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.flip_camera_android_rounded,
                      size: 16,
                      color: Colors.white.withValues(alpha: 0.4),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: _BackTab(
                        label: 'section_info'.tr(),
                        active: _tab == 0,
                        accent: accent,
                        onTap: () => setState(() => _tab = 0),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _BackTab(
                        label: 'section_prompt_blocks'.tr(),
                        active: _tab == 1,
                        accent: accent,
                        onTap: () => setState(() => _tab = 1),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(
                    context,
                  ).copyWith(scrollbars: false),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 2, 16, 18),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: anim,
                        child: SizeTransition(
                          sizeFactor: anim,
                          alignment: Alignment.topCenter,
                          child: child,
                        ),
                      ),
                      child: _tab == 0
                          ? KeyedSubtree(
                              key: const ValueKey('back_info'),
                              child: _buildInfo(),
                            )
                          : KeyedSubtree(
                              key: const ValueKey('back_prompts'),
                              child: _buildPrompts(accent),
                            ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfo() {
    final notes = (_c.creatorNotes?.trim().isNotEmpty ?? false)
        ? _c.creatorNotes!.trim()
        : (_c.description?.trim() ?? '');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_c.tags.isNotEmpty) ...[
          CardTagChips(tags: _c.tags),
          const SizedBox(height: 14),
        ],
        if (notes.isNotEmpty)
          // Rendered as markdown (with the sheet's HTML→markdown + custom inline
          // components) so the description reads the same as the detail sheet.
          _DescriptionMarkdown(notes)
        else if (_c.tags.isEmpty)
          Text(
            'no_preview_available'.tr(),
            style: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
          ),
      ],
    );
  }

  Widget _buildPrompts(Color accent) {
    final sections = _promptSections;
    if (sections.isEmpty) {
      return Text(
        'no_preview_available'.tr(),
        style: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < sections.length; i++)
          _PromptAccordion(
            label: sections[i].label,
            text: sections[i].text.trim(),
            accent: accent,
            expanded: _expanded[i] ?? false,
            onToggle: () =>
                setState(() => _expanded[i] = !(_expanded[i] ?? false)),
          ),
      ],
    );
  }
}

class _BackTab extends StatelessWidget {
  final String label;
  final bool active;
  final Color accent;
  final VoidCallback onTap;
  const _BackTab({
    required this.label,
    required this.active,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? accent.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: active
                ? accent.withValues(alpha: 0.5)
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Center(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: active ? accent : Colors.white.withValues(alpha: 0.6),
            ),
          ),
        ),
      ),
    );
  }
}

/// Renders a character description as markdown, mirroring the detail sheet's
/// Info tab: HTML is converted to markdown first, and the same custom inline
/// components (coloured / glow / gradient text, links, images) are used.
class _DescriptionMarkdown extends StatelessWidget {
  final String text;
  const _DescriptionMarkdown(this.text);

  @override
  Widget build(BuildContext context) {
    return GptMarkdown(
      hasHtmlTags(text) ? htmlToMarkdown(text) : text,
      style: const TextStyle(
        fontSize: 13,
        height: 1.5,
        color: Color(0xD9FFFFFF),
      ),
      onLinkTap: (url, title) async {
        final uri = Uri.tryParse(url);
        if (uri != null) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
      imageBuilder: (context, url, width, height) {
        if (url.startsWith('http://') || url.startsWith('https://')) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: CachedNetworkImage(
              imageUrl: url,
              width: width,
              height: height,
              fit: BoxFit.contain,
            ),
          );
        }
        if (url.startsWith('data:')) {
          final commaIdx = url.indexOf(',');
          if (commaIdx > 0) {
            try {
              final bytes = Uri.parse(url).data!.contentAsBytes();
              return ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  bytes,
                  width: width,
                  height: height,
                  fit: BoxFit.contain,
                ),
              );
            } catch (_) {}
          }
        }
        final file = File(url);
        if (file.existsSync()) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              file,
              width: width,
              height: height,
              fit: BoxFit.contain,
            ),
          );
        }
        return const SizedBox.shrink();
      },
      inlineComponents: [
        HtmlColorMd(),
        GlowTextMd(),
        ColorGlowTextMd(),
        GradientTextMd(),
        BackgroundTextMd(),
        ColoredBoldMd(),
        ColoredUnderscoreBoldMd(),
        ColoredItalicMd(),
        ColoredUnderscoreItalicMd(),
        LinkedImageMd(),
        LinkMd(),
        ImageMd(),
      ],
    );
  }
}

/// An expandable prompt block, matching the detail sheet's accordion: collapsed
/// it shows a 3-line faded preview; tapping expands it to the full text.
class _PromptAccordion extends StatelessWidget {
  final String label;
  final String text;
  final Color accent;
  final bool expanded;
  final VoidCallback onToggle;

  const _PromptAccordion({
    required this.label,
    required this.text,
    required this.accent,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: onToggle,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label.toUpperCase(),
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                        color: accent,
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    turns: expanded ? 0.0 : 0.5,
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOutCubic,
                    child: Icon(
                      Icons.keyboard_arrow_up_rounded,
                      color: Colors.white.withValues(alpha: 0.5),
                      size: 22,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            crossFadeState: expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 280),
            sizeCurve: Curves.easeOutCubic,
            firstChild: ShaderMask(
              shaderCallback: (bounds) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0.45, 1.0],
                colors: [Colors.white, Colors.transparent],
              ).createShader(bounds),
              blendMode: BlendMode.dstIn,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                child: Text(
                  text,
                  maxLines: 3,
                  overflow: TextOverflow.clip,
                  style: const TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: Color(0xCCFFFFFF),
                  ),
                ),
              ),
            ),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: SelectableText(
                text,
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.5,
                  color: Color(0xCCFFFFFF),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
