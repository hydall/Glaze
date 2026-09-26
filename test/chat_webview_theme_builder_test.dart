import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/bridge/chat_webview_theme_builder.dart';

void main() {
  const input = ChatWebViewThemeInput(
    elementOpacity: 0.8,
    elementBlur: 12,
    chatFontSize: 15,
    chatLayout: 'bubble',
    bgDim: 0,
    uiFontWeight: 400,
    userMessageFontWeight: 400,
    charMessageFontWeight: 400,
    userBubbleRadius: 18,
    charBubbleRadius: 18,
    showUserAvatar: true,
    showCharAvatar: true,
    showUserName: true,
    showCharName: true,
  );

  testWidgets('the selection outline colour follows the theme primary', (
    tester,
  ) async {
    late Map<String, String> theme;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3F5C96)),
        ),
        home: Builder(
          builder: (context) {
            theme = ChatWebViewThemeBuilder.build(context, input);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    // Bubble layout paints the selected message body with a hex colour
    // (`box-shadow: 0 0 0 2px var(--vk-blue)`) while the translucent
    // background uses the matching `--vk-blue-rgb` triplet. Both have to come
    // from the same themed primary. The builder used to emit only the triplet,
    // so the outline stayed on the hardcoded red `--vk-blue` default and
    // ignored Material You.
    expect(theme['vk-blue'], isNotNull);
    expect(theme['vk-blue'], theme['primary-color']);
    expect(theme['vk-blue'], isNot('#c42a4a'));
  });
}
