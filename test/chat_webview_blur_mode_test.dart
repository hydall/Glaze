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
    test('true where the WebView is part of the Flutter frame', () {
      // Windows composites WebView2 into a Flutter texture, and the iOS
      // embedder blurs platform views itself.
      expect(chatWebViewBlurIsFlutterSide(TargetPlatform.windows), isTrue);
      expect(chatWebViewBlurIsFlutterSide(TargetPlatform.iOS), isTrue);
    });

    test('follows the Android composition mode', () {
      expect(chatWebViewUsesHybridComposition(), isFalse);
      expect(chatWebViewBlurIsFlutterSide(TargetPlatform.android), isTrue);
    });

    test('false where the WebView stays an unsampled platform view', () {
      expect(chatWebViewBlurIsFlutterSide(TargetPlatform.macOS), isFalse);
      expect(chatWebViewBlurIsFlutterSide(TargetPlatform.linux), isFalse);
      expect(chatWebViewBlurIsFlutterSide(TargetPlatform.fuchsia), isFalse);
    });

    test('defaults to the running platform', () {
      expect(
        chatWebViewBlurIsFlutterSide(),
        chatWebViewBlurIsFlutterSide(defaultTargetPlatform),
      );
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
