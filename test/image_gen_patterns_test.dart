import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/constants/image_gen_patterns.dart';

void main() {
  group('ImgGenPatterns', () {
    group('hasAnyImageTag', () {
      test('detects [IMG:GEN] bare tag', () {
        expect(ImgGenPatterns.hasAnyImageTag('Hello [IMG:GEN:]'), isTrue);
      });

      test('detects [IMG:GEN:json] tag', () {
        expect(
          ImgGenPatterns.hasAnyImageTag('Hello [IMG:GEN:{"prompt":"test"}]'),
          isTrue,
        );
      });

      test('detects [IMG:RESULT:url] tag', () {
        expect(
          ImgGenPatterns.hasAnyImageTag('Result [IMG:RESULT:https://img.png]'),
          isTrue,
        );
      });

      test('detects [IMG:ERROR:msg] tag', () {
        expect(
          ImgGenPatterns.hasAnyImageTag('Error [IMG:ERROR:timeout]'),
          isTrue,
        );
      });

      test('detects HTML img with data-iig-instruction single quotes', () {
        const html =
            """<img data-iig-instruction='{"style":"manga"}' src="[IMG:GEN]">""";
        expect(ImgGenPatterns.hasAnyImageTag(html), isTrue);
      });

      test('detects HTML img with data-iig-instruction double quotes', () {
        const html =
            '''<img data-iig-instruction="{"style":"manga"}" src="[IMG:GEN]">''';
        expect(ImgGenPatterns.hasAnyImageTag(html), isTrue);
      });

      test('returns false for plain text', () {
        expect(ImgGenPatterns.hasAnyImageTag('Just a normal message'), isFalse);
      });

      test('returns false for empty string', () {
        expect(ImgGenPatterns.hasAnyImageTag(''), isFalse);
      });
    });

    group('imgGenRegex', () {
      test('matches bare [IMG:GEN]', () {
        final match = ImgGenPatterns.imgGenRegex.firstMatch('[IMG:GEN:]');
        expect(match, isNotNull);
        expect(match!.group(1), '');
      });

      test('matches [IMG:GEN:json] and captures json', () {
        final match =
            ImgGenPatterns.imgGenRegex.firstMatch('[IMG:GEN:{"prompt":"sunset"}]');
        expect(match, isNotNull);
        expect(match!.group(1), '{"prompt":"sunset"}');
      });

      test('no match for [IMG:RESULT:...]', () {
        expect(ImgGenPatterns.imgGenRegex.hasMatch('[IMG:RESULT:x]'), isFalse);
      });
    });

    group('imgResultRegex', () {
      test('matches and captures URL', () {
        final match =
            ImgGenPatterns.imgResultRegex.firstMatch('[IMG:RESULT:https://x.png]');
        expect(match, isNotNull);
        expect(match!.group(1), 'https://x.png');
      });
    });

    group('imgErrorRegex', () {
      test('matches and captures error message', () {
        final match =
            ImgGenPatterns.imgErrorRegex.firstMatch('[IMG:ERROR:timeout]');
        expect(match, isNotNull);
        expect(match!.group(1), 'timeout');
      });
    });

    group('stripHtmlImgTags', () {
      test('removes HTML img tags with data-iig-instruction', () {
        const html =
            """Hello <img data-iig-instruction='{"style":"manga"}' src="[IMG:GEN]"> world""";
        final result = ImgGenPatterns.stripHtmlImgTags(html);
        expect(result, 'Hello  world');
      });
    });

    group('strip regexes', () {
      test('imgGenStripRegex strips [IMG:GEN:...]', () {
        const text = 'Before [IMG:GEN:{"p":"x"}] After';
        final result = text.replaceAll(ImgGenPatterns.imgGenStripRegex, '');
        expect(result, 'Before  After');
      });

      test('imgResultStripRegex strips [IMG:RESULT:...]', () {
        const text = 'Before [IMG:RESULT:https://x.png] After';
        final result = text.replaceAll(ImgGenPatterns.imgResultStripRegex, '');
        expect(result, 'Before  After');
      });

      test('imgErrorStripRegex strips [IMG:ERROR:...]', () {
        const text = 'Before [IMG:ERROR:fail] After';
        final result = text.replaceAll(ImgGenPatterns.imgErrorStripRegex, '');
        expect(result, 'Before  After');
      });
    });

    group('htmlIigTagRegex', () {
      test('captures instruction from single-quoted attribute', () {
        const html =
            """<img data-iig-instruction='{"style":"manga","prompt":"test"}' src="[IMG:GEN]">""";
        final match = ImgGenPatterns.htmlIigTagRegex.firstMatch(html);
        expect(match, isNotNull);
        expect(match!.group(1), '{"style":"manga","prompt":"test"}');
      });
    });

    group('htmlIigTagDoubleRegex', () {
      test('matches double-quoted data-iig-instruction', () {
        const html =
            '<img data-iig-instruction="test_instruction" src="[IMG:GEN]">';
        expect(ImgGenPatterns.htmlIigTagDoubleRegex.hasMatch(html), isTrue);
      });
    });

    group('base64DataUrlRegex', () {
      test('matches base64 data URL', () {
        const dataUrl =
            'data:image/png;base64,'
            'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
            'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
            'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
            'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
        expect(ImgGenPatterns.base64DataUrlRegex.hasMatch(dataUrl), isTrue);
      });

      test('no match for short data', () {
        expect(
          ImgGenPatterns.base64DataUrlRegex
              .hasMatch('data:image/png;base64,SHORT'),
          isFalse,
        );
      });
    });

    group('reasoningSpans', () {
      test('covers <think> and <thinking>, whatever the case', () {
        expect(ImgGenPatterns.reasoningSpans('a <think>x</think> b'), [
          (2, 18),
        ]);
        expect(ImgGenPatterns.reasoningSpans('<thinking>x</thinking>'), [
          (0, 22),
        ]);
        expect(ImgGenPatterns.reasoningSpans('<THINK>x</THINK>'), [(0, 16)]);
      });

      test('stops at the first close, so two blocks stay two', () {
        expect(
          ImgGenPatterns.reasoningSpans('<think>a</think> mid <think>b</think>'),
          [(0, 16), (21, 37)],
        );
      });

      test('an unclosed block is not a span', () {
        // The WebView formatter folds a block only once it closes; a tag after
        // an unterminated <think> still belongs to the message (INV-IG11).
        expect(ImgGenPatterns.reasoningSpans('<think>drafting'), isEmpty);
      });

      test('text with no reasoning costs nothing', () {
        expect(ImgGenPatterns.reasoningSpans('plain [IMG:GEN]'), isEmpty);
      });

      test('overlapsSpan is true for any intersection', () {
        const spans = [(10, 20)];
        expect(ImgGenPatterns.overlapsSpan(spans, 12, 15), isTrue);
        expect(ImgGenPatterns.overlapsSpan(spans, 5, 12), isTrue);
        expect(ImgGenPatterns.overlapsSpan(spans, 0, 10), isFalse);
        expect(ImgGenPatterns.overlapsSpan(spans, 20, 25), isFalse);
      });
    });
  });
}
