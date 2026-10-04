import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/shared/widgets/noise_overlay.dart';

void main() {
  testWidgets('bakes one shared tile for surfaces of different cell sizes', (
    tester,
  ) async {
    // A tint/alpha pair no other test uses, so the first build is a cache miss
    // and the bake is observable.
    const tint = Color(0xFF0A0B0C);
    const opacity = 0.37;
    const intensity = 0.91;

    NoiseOverlay.debugResetBakeCount();

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              // Small surface: stepFor(40 * 40) == 1.
              SizedBox(
                width: 40,
                height: 40,
                child: NoiseOverlay(
                  opacity: opacity,
                  intensity: intensity,
                  tint: tint,
                ),
              ),
              // Large surface: stepFor(400 * 400) == 4.
              SizedBox(
                width: 400,
                height: 400,
                child: NoiseOverlay(
                  opacity: opacity,
                  intensity: intensity,
                  tint: tint,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // The grain does not depend on the cell size, so the second size must reuse
    // the tile the first started — one bake, not one per size.
    expect(NoiseOverlay.debugBakeCount, 1);
  });
}
