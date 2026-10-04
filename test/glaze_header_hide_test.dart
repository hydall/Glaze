import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/shared/widgets/glaze_scaffold.dart';

/// The chat's triggered-entries panel is anchored under the header and hides
/// with it, but it lives in the chat body (its measured height insets the top
/// of the message list), so it cannot sit inside the header's own
/// AnimatedSlide. These cover the shared travel math that keeps the two
/// moving as one unit: an AnimatedSlide offset is a fraction of the CHILD's
/// height, so the panel needs its own fraction to cover the header's pixels.
void main() {
  group('glazeHeaderHideSlideFor', () {
    test('an overlay as tall as the header reuses the header factor', () {
      expect(
        glazeHeaderHideSlideFor(headerHeight: 90, overlayHeight: 90),
        kGlazeHeaderHideSlideFactor,
      );
    });

    test('a taller overlay slides a smaller fraction of itself', () {
      // Same pixel travel as the header: 90 * 1.5 = 135px over a 270px panel.
      expect(
        glazeHeaderHideSlideFor(headerHeight: 90, overlayHeight: 270),
        closeTo(0.5, 1e-9),
      );
    });

    test('a shorter overlay slides a larger fraction of itself', () {
      expect(
        glazeHeaderHideSlideFor(headerHeight: 90, overlayHeight: 45),
        closeTo(3.0, 1e-9),
      );
    });

    test('travels the header distance in pixels at any overlay height', () {
      const headerHeight = 90.0;
      for (final overlayHeight in <double>[20, 45, 90, 180, 400]) {
        final pixels =
            glazeHeaderHideSlideFor(
              headerHeight: headerHeight,
              overlayHeight: overlayHeight,
            ) *
            overlayHeight;
        expect(
          pixels,
          closeTo(headerHeight * kGlazeHeaderHideSlideFactor, 1e-9),
          reason: 'overlay height $overlayHeight must not outrun the header',
        );
      }
    });

    test('falls back to the header factor before the overlay is measured', () {
      expect(
        glazeHeaderHideSlideFor(headerHeight: 90, overlayHeight: 0),
        kGlazeHeaderHideSlideFactor,
      );
    });
  });
}
