import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/utils/html_to_markdown.dart';
import 'package:glaze_flutter/shared/widgets/colored_markdown.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// #112: "Can't see spoiler text in info box — tapping it doesn't reveal it".
///
/// Glaze does not hide spoilers behind a tap; it reveals them on sight. A
/// JanitorAI spoiler is text painted the same colour as its own highlight, and
/// `htmlToMarkdown` drops the hiding colour so the highlight can show with
/// readable text instead. `BackgroundTextMd` then painted that text white
/// whatever the highlight was — so a spoiler hidden behind a pale colour came
/// out white-on-white, exactly as unreadable as it started.
void main() {
  const fallback = Color(0xFF123456);

  group('readableOn', () {
    test('a pale highlight takes dark text', () {
      expect(readableOn(Colors.white, fallback: fallback), Colors.black);
      expect(
        readableOn(const Color(0xFFEEEEEE), fallback: fallback),
        Colors.black,
      );
    });

    test('a dark highlight takes light text', () {
      expect(readableOn(Colors.black, fallback: fallback), Colors.white);
      expect(
        readableOn(const Color(0xFF222222), fallback: fallback),
        Colors.white,
      );
    });

    test('the crossover is the contrast ratio, not the halfway point', () {
      // A luminance of 0.5 is the usual shortcut and it sits in the wrong
      // place: the two ratios actually meet at ~0.179, so everything from mid
      // grey up already reads better in black. #666666 is just below that
      // crossover and #808080 just above it — the shortcut would have painted
      // both white.
      expect(
        readableOn(const Color(0xFF666666), fallback: fallback),
        Colors.white,
      );
      expect(
        readableOn(const Color(0xFF808080), fallback: fallback),
        Colors.black,
      );
    });

    test('a highlight too transparent to be a background defers', () {
      // The text is sitting on the surface, so it has to read against that.
      expect(
        readableOn(const Color(0x10FFFFFF), fallback: fallback),
        fallback,
      );
      expect(readableOn(Colors.transparent, fallback: fallback), fallback);
    });

    test('the default accent tint reads too', () {
      // `_markMarker` falls back to this when a <mark> carries no background.
      // It is light enough to want dark text, which is the point: the answer
      // comes from the colour rather than from a guess about highlights.
      expect(
        readableOn(const Color(0xFF8B5CF6), fallback: fallback),
        Colors.black,
      );
    });
  });

  group('the marker a spoiler becomes', () {
    test("JanitorAI's span-wrapping-mark collapses to one highlight", () {
      final markdown = htmlToMarkdown(
        '<p><span style="color: rgb(255, 255, 255);">'
        '<mark style="background-color: rgb(255, 255, 255);">the secret</mark>'
        '</span></p>',
      );
      expect(markdown, contains('==bg:#ffffff==the secret=='));
      // The hiding colour is gone: that is the reveal.
      expect(markdown, isNot(contains('==hc:')));
    });

    test('a bare mark keeps its own background', () {
      final markdown = htmlToMarkdown(
        '<p><mark style="background-color: #000000;">the secret</mark></p>',
      );
      expect(markdown, contains('==bg:#000000==the secret=='));
    });

    test('a span with a background and no mark reveals the same way', () {
      final markdown = htmlToMarkdown(
        '<p><span style="color:#eeeeee;background-color:#eeeeee;">'
        'the secret</span></p>',
      );
      expect(markdown, contains('==bg:#eeeeee=='));
      expect(markdown, contains('the secret'));
    });
  });

  group('#112 — the revealed text is readable on the page', () {
    Future<Color?> paintedColor(WidgetTester tester, String markdown) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GptMarkdown(
              markdown,
              style: const TextStyle(color: fallback),
              inlineComponents: [BackgroundTextMd()],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final text = tester.widget<Text>(find.text('the secret'));
      return text.style?.color;
    }

    testWidgets('a spoiler hidden behind white is not painted white', (
      tester,
    ) async {
      expect(
        await paintedColor(tester, '==bg:#ffffff==the secret=='),
        Colors.black,
      );
    });

    testWidgets('a spoiler hidden behind black still reads', (tester) async {
      expect(
        await paintedColor(tester, '==bg:#000000==the secret=='),
        Colors.white,
      );
    });
  });
}
