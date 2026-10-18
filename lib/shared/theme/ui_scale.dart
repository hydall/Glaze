import 'package:flutter/material.dart';

/// App-wide rounding controls from the Appearance settings.
///
/// [cornerScale] multiplies the design radii of buttons, cards, sheets and
/// dialogs, so `0` squares everything off while `1` keeps the shipped look.
/// [avatarRoundness] is a fraction of a full circle: `1` is a circle, `0` a
/// square.
@immutable
class GlazeUiScale extends ThemeExtension<GlazeUiScale> {
  final double cornerScale;
  final double avatarRoundness;

  const GlazeUiScale({this.cornerScale = 1.0, this.avatarRoundness = 1.0});

  double radius(double base) => base * cornerScale;

  BorderRadius borderRadius(double base) => BorderRadius.circular(radius(base));

  /// Corner radius of a square avatar of [size] px.
  double avatarRadius(double size) => (size / 2) * avatarRoundness;

  @override
  GlazeUiScale copyWith({double? cornerScale, double? avatarRoundness}) =>
      GlazeUiScale(
        cornerScale: cornerScale ?? this.cornerScale,
        avatarRoundness: avatarRoundness ?? this.avatarRoundness,
      );

  @override
  GlazeUiScale lerp(ThemeExtension<GlazeUiScale>? other, double t) {
    if (other is! GlazeUiScale) return this;
    return GlazeUiScale(
      cornerScale: cornerScale + (other.cornerScale - cornerScale) * t,
      avatarRoundness:
          avatarRoundness + (other.avatarRoundness - avatarRoundness) * t,
    );
  }
}

extension GlazeUiScaleContext on BuildContext {
  GlazeUiScale get glazeUiScale =>
      Theme.of(this).extension<GlazeUiScale>() ?? const GlazeUiScale();

  double glazeRadius(double base) => glazeUiScale.radius(base);

  BorderRadius glazeBorderRadius(double base) =>
      glazeUiScale.borderRadius(base);

  /// Scales every corner of [radius] by the current UI corner scale.
  BorderRadius scaleBorderRadius(BorderRadius radius) {
    final scale = glazeUiScale.cornerScale;
    if (scale == 1.0) return radius;
    Radius scaleRadius(Radius r) => Radius.elliptical(r.x * scale, r.y * scale);
    return BorderRadius.only(
      topLeft: scaleRadius(radius.topLeft),
      topRight: scaleRadius(radius.topRight),
      bottomLeft: scaleRadius(radius.bottomLeft),
      bottomRight: scaleRadius(radius.bottomRight),
    );
  }
}
