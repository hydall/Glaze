import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// App-wide [ScrollBehavior]: Android overscroll uses [GlazeStretchOverscroll]
/// instead of the framework's [StretchingOverscrollIndicator].
///
/// The framework indicator renders the stretch through an
/// [ImageFiltered]-style offscreen layer (fragment shader on Impeller,
/// matrix-filtered saveLayer otherwise). A [BackdropFilter] inside an
/// offscreen layer cannot read the real backdrop, so every glass surface
/// inside a scroll view lost its blur for the duration of the stretch.
/// [GlazeStretchOverscroll] applies the same spring physics through a plain
/// geometry [Transform] (no offscreen layer), which backdrop filters see
/// straight through.
class GlazeScrollBehavior extends MaterialScrollBehavior {
  const GlazeScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    switch (getPlatform(context)) {
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
        return GlazeStretchOverscroll(
          axisDirection: details.direction,
          clipBehavior: details.decorationClipBehavior ?? Clip.hardEdge,
          child: child,
        );
      case TargetPlatform.iOS:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return super.buildOverscrollIndicator(context, child, details);
    }
  }
}

/// Port of the framework's [StretchingOverscrollIndicator] (Flutter 3.44,
/// including `_StretchController`'s Android EdgeEffect spring physics) with
/// one deliberate difference: the visual effect is a plain scale [Transform]
/// — the framework's pre-shader approximation, minus its
/// `FilterQuality.medium` (which would recreate the offscreen layer this fork
/// exists to avoid).
class GlazeStretchOverscroll extends StatefulWidget {
  const GlazeStretchOverscroll({
    super.key,
    required this.axisDirection,
    this.notificationPredicate = defaultScrollNotificationPredicate,
    this.clipBehavior = Clip.hardEdge,
    required this.child,
  });

  final AxisDirection axisDirection;
  final ScrollNotificationPredicate notificationPredicate;
  final Clip clipBehavior;
  final Widget child;

  Axis get axis => axisDirectionToAxis(axisDirection);

  @override
  State<GlazeStretchOverscroll> createState() => _GlazeStretchOverscrollState();
}

class _GlazeStretchOverscrollState extends State<GlazeStretchOverscroll>
    with TickerProviderStateMixin {
  late final _StretchController _stretchController = _StretchController(
    vsync: this,
  );
  ScrollNotification? _lastNotification;
  OverscrollNotification? _lastOverscrollNotification;

  double _totalOverscroll = 0.0;

  bool _accepted = true;

  bool _handleScrollNotification(ScrollNotification notification) {
    if (!widget.notificationPredicate(notification)) {
      return false;
    }
    if (notification.metrics.axis != widget.axis) {
      return false;
    }
    if (notification is OverscrollNotification) {
      _lastOverscrollNotification = notification;
      if (_lastNotification.runtimeType is! OverscrollNotification) {
        final confirmationNotification = _StretchIndicatorNotification(
          leading: notification.overscroll < 0.0,
        );
        confirmationNotification.dispatch(context);
        _accepted = confirmationNotification.enabled;
      }

      if (_accepted) {
        _totalOverscroll += notification.overscroll;

        if (notification.velocity != 0.0) {
          assert(notification.dragDetails == null);
          _stretchController.absorbImpact(notification.velocity);
        } else {
          assert(notification.overscroll != 0.0);
          if (notification.dragDetails != null) {
            // Clamp the overscroll relative to the viewport length — the
            // furthest a single pointer could pull — because multiple
            // pointers multiply the reported overscroll.
            final double viewportDimension =
                notification.metrics.viewportDimension;
            final double distanceForPull =
                _totalOverscroll / viewportDimension;
            final double clampedOverscroll = clampDouble(
              distanceForPull,
              -1.0,
              1.0,
            );
            _stretchController.pull(clampedOverscroll);
          }
        }
      }
    } else if (notification is ScrollEndNotification) {
      double velocity = switch (widget.axis) {
        Axis.vertical =>
          notification.dragDetails?.velocity.pixelsPerSecond.dy ?? 0.0,
        Axis.horizontal =>
          notification.dragDetails?.velocity.pixelsPerSecond.dx ?? 0.0,
      };

      // The fling velocity from drag details is directed against the scroll
      // offset, so for reversed axis directions the value must be inverted.
      if (notification.metrics.axisDirection == AxisDirection.left ||
          notification.metrics.axisDirection == AxisDirection.up) {
        velocity = -velocity;
      }

      _totalOverscroll = 0.0;
      _stretchController.scrollEnd(velocity);
    } else if (notification is ScrollUpdateNotification) {
      _totalOverscroll = 0.0;
      _stretchController.scrollEnd(0.0);
    }
    _lastNotification = notification;
    return false;
  }

  AlignmentGeometry _alignment(double stretchStrength) {
    final bool isForward = stretchStrength > 0;
    if (widget.axis == Axis.vertical) {
      return isForward
          ? AlignmentDirectional.topCenter
          : AlignmentDirectional.bottomCenter;
    }
    if (Directionality.of(context) == TextDirection.rtl) {
      return isForward
          ? AlignmentDirectional.centerEnd
          : AlignmentDirectional.centerStart;
    }
    return isForward
        ? AlignmentDirectional.centerStart
        : AlignmentDirectional.centerEnd;
  }

  @override
  void dispose() {
    _stretchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: AnimatedBuilder(
        animation: _stretchController,
        builder: (BuildContext context, Widget? child) {
          final double stretch = _stretchController.overscroll;
          final double mainAxisSize = switch (widget.axis) {
            Axis.horizontal => MediaQuery.widthOf(context),
            Axis.vertical => MediaQuery.heightOf(context),
          };

          final double viewportDimension =
              _lastOverscrollNotification?.metrics.viewportDimension ??
              mainAxisSize;

          double overscroll = -stretch;
          if (widget.axisDirection == AxisDirection.up ||
              widget.axisDirection == AxisDirection.left) {
            overscroll = -overscroll;
          }

          var x = 1.0;
          var y = 1.0;
          switch (widget.axis) {
            case Axis.horizontal:
              x += overscroll.abs();
            case Axis.vertical:
              y += overscroll.abs();
          }

          final Widget transform = Transform(
            alignment: _alignment(overscroll),
            transform: Matrix4.diagonal3Values(x, y, 1.0),
            child: widget.child,
          );

          // Only clip when the viewport is smaller than the screen along the
          // main axis; a full-screen viewport can't leak stretched content.
          return ClipRect(
            clipBehavior: stretch != 0.0 && viewportDimension != mainAxisSize
                ? widget.clipBehavior
                : Clip.none,
            child: transform,
          );
        },
      ),
    );
  }
}

/// [OverscrollIndicatorNotification] whose acceptance can be read from
/// outside the framework library (the base class's `accepted` field is
/// protected).
class _StretchIndicatorNotification extends OverscrollIndicatorNotification {
  _StretchIndicatorNotification({required super.leading});

  bool enabled = true;

  @override
  void disallowIndicator() {
    enabled = false;
    super.disallowIndicator();
  }
}

/// Verbatim port of the framework's private `_StretchController`
/// (Android EdgeEffect spring physics).
class _StretchController extends Listenable {
  _StretchController({required this.vsync});

  final TickerProvider vsync;
  AnimationController? _controller;

  final ValueNotifier<double> _overscrollNotifier = ValueNotifier<double>(0.0);
  double get overscroll => _overscrollNotifier.value;
  set overscroll(double newValue) {
    _overscrollNotifier.value = clampDouble(
      newValue,
      minOverscroll,
      maxOverscroll,
    );
  }

  /// Overscroll captured when an ongoing release animation is interrupted by
  /// a new pull, added back in so the hand-off doesn't jump.
  double _interruptedOverscroll = 0.0;

  // Constants from Android.
  static const double _exponentialScalar = math.e / 0.33;
  static const double _stretchIntensity = 0.016;

  static const double minOverscroll = -1.0;
  static const double maxOverscroll = 1.0;

  static const double _flingVelocityFriction = 1 / 6000;
  static const double _absorbImpactVelocityFriction = 1 / 3000;
  static const double _maxFlingVelocity = 0.5;
  static const double _maxAbsorbImpactVelocity = 1.25;

  // Physical constants ported from Android's EdgeEffect.java, with the
  // framework's empirical time correction to match platform timing.
  static const double kNaturalFrequency = 24.657;
  static const double kDampingRatio = 0.98;
  static const double kTimeCorrectionFactor = 0.8;
  static const double kStiffness = kNaturalFrequency * kNaturalFrequency;

  static final SpringDescription _kStretchSpringDescription =
      SpringDescription.withDampingRatio(
        mass: 1,
        stiffness: kStiffness * kTimeCorrectionFactor * kTimeCorrectionFactor,
        ratio: kDampingRatio,
      );

  @override
  void addListener(VoidCallback listener) {
    _overscrollNotifier.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _overscrollNotifier.removeListener(listener);
  }

  SpringSimulation _createStretchSimulation(double velocity) {
    return SpringSimulation(
      _kStretchSpringDescription,
      overscroll,
      0.0,
      velocity * kTimeCorrectionFactor,
    );
  }

  /// Handle a fling to the edge of the viewport at a particular velocity.
  void absorbImpact(double velocity) {
    if (velocity == 0.0) {
      return;
    }
    final double scaledVelocity = clampDouble(
      velocity * _absorbImpactVelocityFriction,
      -_maxAbsorbImpactVelocity,
      _maxAbsorbImpactVelocity,
    );

    animate(_createStretchSimulation(scaledVelocity));
  }

  /// Called when the overscroll ends to trigger a release animation.
  void scrollEnd(double velocity) {
    if (velocity == 0.0 && overscroll == 0.0) {
      return;
    }
    final double scaledVelocity = clampDouble(
      -(velocity * _flingVelocityFriction),
      -_maxFlingVelocity,
      _maxFlingVelocity,
    );

    if (_controller == null) {
      animate(_createStretchSimulation(scaledVelocity));
    }
  }

  void animate(Simulation simulation) {
    final controller = AnimationController.unbounded(vsync: vsync)
      ..addListener(() {
        final double newOverscroll = _controller?.value ?? 0.0;
        overscroll = newOverscroll;
      })
      ..animateWith(simulation).whenComplete(() {
        overscroll = 0.0;
        _interruptedOverscroll = 0.0;
        _controller!.dispose();
        _controller = null;
      });

    _controller?.dispose();
    _controller = controller;
  }

  /// Handle a user-driven overscroll; `normalizedOverscroll` is the scroll
  /// distance in logical pixels divided by the main-axis viewport extent.
  void pull(double normalizedOverscroll) {
    if (_controller != null) {
      _interruptedOverscroll = _controller!.value;
      _controller!.dispose();
      _controller = null;
    }

    final pullDistance = normalizedOverscroll;
    final double absDistance = pullDistance.abs();
    final double linearIntensity = _stretchIntensity * absDistance;
    final double exponentialIntensity =
        _stretchIntensity * (1 - math.exp(-absDistance * _exponentialScalar));

    final double directionSign = pullDistance.sign;
    final double newOverscroll =
        directionSign * (linearIntensity + exponentialIntensity);
    overscroll = newOverscroll + _interruptedOverscroll;
  }

  void dispose() {
    _controller?.dispose();
    _overscrollNotifier.dispose();
  }
}
