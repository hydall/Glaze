import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/bridge/chat_webview_blur_mode.dart';
import 'package:glaze_flutter/features/chat/widgets/chat_blur_region_tracker.dart';
import 'package:glaze_flutter/features/chat/widgets/chat_input_bar.dart';
import 'package:glaze_flutter/shared/widgets/glass_surface.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('chatWebViewBlurIsFlutterSide', () {
    test('the blur is mirrored into the page on every platform', () {
      // Sampling the WebView from a Flutter BackdropFilter is possible on some
      // of these, but it is off by default: the backdrop under the glass is
      // new pixels on every frame the reader scrolls, so that blur can never
      // be reused. Opting back in is a dart-define.
      for (final platform in TargetPlatform.values) {
        expect(
          chatWebViewBlurIsFlutterSide(platform),
          isFalse,
          reason: '$platform must mirror the blur into the page',
        );
      }
    });

    test('Android keeps the WebView on hybrid composition', () {
      // Texture layer hybrid composition exists only to make the WebView
      // sampleable, and it copies the WebView's frame into a texture to do it.
      // Nothing samples it here, so nothing should pay for that copy.
      expect(chatWebViewUsesHybridComposition(), isTrue);
    });

    test('defaults to the running platform', () {
      expect(
        chatWebViewBlurIsFlutterSide(),
        chatWebViewBlurIsFlutterSide(defaultTargetPlatform),
      );
    });
  });

  // The strips are positioned from rects Flutter measures, so a strip is only
  // ever where the chrome is if the measurement is taken while the chrome
  // moves. The pass used to hold still through keyboard and drawer animations
  // to keep per-frame rect pushes off the bridge, which parked every strip
  // where its widget had been until the layout settled.
  group('ChatBlurRegionRegistry', () {
    testWidgets('measures a tracked overlay where it is mid-animation', (
      tester,
    ) async {
      final registry = ChatBlurRegionRegistry();
      addTearDown(registry.dispose);
      final referenceKey = GlobalKey();
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      Widget build({required bool raised}) => Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          key: referenceKey,
          width: 400,
          height: 800,
          child: ChatBlurRegionScope(
            registry: registry,
            child: Stack(
              children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 200),
                  left: 0,
                  right: 0,
                  bottom: raised ? 300 : 0,
                  height: 60,
                  child: const BlurRegionTracker(
                    id: 'composer',
                    radius: 20,
                    child: SizedBox.expand(),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      RenderBox reference() =>
          referenceKey.currentContext!.findRenderObject()! as RenderBox;

      await tester.pumpWidget(build(raised: false));
      final atRest = registry.measure(reference()).single;
      expect(atRest.rect.top, 740);
      expect(atRest.radius, 20);

      // The keyboard opens: the pill is on its way up, and so is its strip.
      await tester.pumpWidget(build(raised: true));
      await tester.pump(const Duration(milliseconds: 100));
      final midFlight = registry.measure(reference()).single;
      expect(midFlight.rect.top, lessThan(atRest.rect.top));
      expect(midFlight.rect.top, greaterThan(440));

      await tester.pumpAndSettle();
      expect(registry.measure(reference()).single.rect.top, 440);
    });
  });

  group('ChatInputBar blur wiring', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Widget build({required bool blurViaWebView, BackdropKey? backdropKey}) {
      return ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: ChatInputBar(
              onSend: (_) async => true,
              isGenerating: false,
              blurViaWebView: blurViaWebView,
              backdropKey: backdropKey,
            ),
          ),
        ),
      );
    }

    testWidgets('mirrors its rects only while the blur lives in the page', (
      tester,
    ) async {
      await tester.pumpWidget(build(blurViaWebView: true));
      expect(find.byType(BlurRegionTracker), findsWidgets);

      await tester.pumpWidget(build(blurViaWebView: false));
      expect(find.byType(BlurRegionTracker), findsNothing);
    });

    testWidgets('blurs itself and shares one capture with the chrome', (
      tester,
    ) async {
      final key = BackdropKey();
      await tester.pumpWidget(build(blurViaWebView: false, backdropKey: key));

      final surfaces = tester
          .widgetList<GlassSurface>(find.byType(GlassSurface))
          .toList();
      expect(surfaces, isNotEmpty);
      // Nothing defers to the page any more, and the pill floating over the
      // body carries the shared capture.
      expect(surfaces.every((s) => !s.blurViaWebView), isTrue);
      expect(surfaces.where((s) => s.backdropKey == key), isNotEmpty);
    });
  });
}
