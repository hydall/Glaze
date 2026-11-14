import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/utils/html_to_markdown.dart';

void main() {
  group('htmlToMarkdown — JanitorAI bio constructs', () {
    test('image wrapped in a link → linked-image markdown', () {
      const html =
          '<a href="https://discord.gg/sQDSpzXdfu" target="_blank">'
          '<img src="https://ella.janitorai.com/media-approved/6Bl0r5.webp"></a>';
      final md = htmlToMarkdown(html);
      expect(
        md.contains(
          '[![](https://ella.janitorai.com/media-approved/6Bl0r5.webp)]'
          '(https://discord.gg/sQDSpzXdfu)',
        ),
        isTrue,
        reason: 'got: $md',
      );
    });

    test('spoiler: colour span wrapping bg mark → single ==bg:== marker', () {
      const html =
          '<span style="color: rgb(153, 153, 153);">'
          '<mark style="background-color: rgb(153, 153, 153); color: inherit;">'
          'hidden text</mark></span>';
      final md = htmlToMarkdown(html);
      expect(md, contains('==bg:#999999==hidden text=='));
      // Must NOT leave literal <mark> or nested colour marker.
      expect(md.contains('<mark'), isFalse, reason: 'got: $md');
      expect(md.contains('==hc:'), isFalse, reason: 'got: $md');
    });

    test('standalone mark without background → accent bg marker', () {
      const html = '<mark>note</mark>';
      final md = htmlToMarkdown(html);
      expect(md, contains('==bg:#8b5cf6==note=='));
    });

    test('unordered list → "- " bullets', () {
      const html = '<ul><li>first</li><li>second</li></ul>';
      final md = htmlToMarkdown(html);
      expect(md, contains('- first'));
      expect(md, contains('- second'));
      expect(md.contains('<li>'), isFalse, reason: 'got: $md');
    });

    test('ordered list → numbered items', () {
      const html = '<ol><li>alpha</li><li>beta</li></ol>';
      final md = htmlToMarkdown(html);
      expect(md, contains('1. alpha'));
      expect(md, contains('2. beta'));
    });

    test('list item keeps inline formatting as markdown', () {
      const html = '<ul><li><strong>bold</strong> and <em>italic</em></li></ul>';
      final md = htmlToMarkdown(html);
      expect(md, contains('- **bold** and *italic*'));
    });
  });

  group('splitBioAlignment', () {
    test('unaligned text → single left segment (unchanged render)', () {
      final segs = splitBioAlignment('plain description');
      expect(segs, hasLength(1));
      expect(segs.single.align, 'left');
      expect(segs.single.text, 'plain description');
    });

    test('centered paragraph → one center segment', () {
      final md = htmlToMarkdown(
        '<p style="text-align: center;"><strong>Banner</strong></p>',
      );
      final segs = splitBioAlignment(md);
      expect(segs, hasLength(1));
      expect(segs.single.align, 'center');
      expect(segs.single.text, contains('**Banner**'));
    });

    test('left paragraph is NOT wrapped (stays default)', () {
      final md = htmlToMarkdown('<p>ordinary line</p>');
      expect(md.contains('\x02'), isFalse, reason: 'got: $md');
      final segs = splitBioAlignment(md);
      expect(segs.single.align, 'left');
    });

    test('mixed: left text then centered image → two ordered segments', () {
      final md = htmlToMarkdown(
        '<p>intro text</p>'
        '<p style="text-align: center;"><img src="https://x/y.webp"></p>',
      );
      final segs = splitBioAlignment(md);
      expect(segs, hasLength(2));
      expect(segs[0].align, 'left');
      expect(segs[0].text, contains('intro text'));
      expect(segs[1].align, 'center');
      expect(segs[1].text, contains('![](https://x/y.webp)'));
    });

    test('centered linked image keeps the linked-image markdown', () {
      final md = htmlToMarkdown(
        '<p style="text-align: center;">'
        '<a href="https://discord.gg/x"><img src="https://ella/z.webp"></a></p>',
      );
      final segs = splitBioAlignment(md);
      expect(segs.single.align, 'center');
      expect(
        segs.single.text,
        contains('[![](https://ella/z.webp)](https://discord.gg/x)'),
      );
    });

    test('no sentinel leaks into any segment text', () {
      final md = htmlToMarkdown(
        '<p style="text-align: right;">a</p><p>b</p>'
        '<p style="text-align: justify;">c</p>',
      );
      final segs = splitBioAlignment(md);
      for (final s in segs) {
        expect(s.text.contains('\x02'), isFalse, reason: 'leak in: ${s.text}');
        expect(s.text.contains('\x1f'), isFalse, reason: 'leak in: ${s.text}');
      }
      expect(segs.map((s) => s.align), containsAllInOrder(['right', 'left', 'justify']));
    });
  });
}
