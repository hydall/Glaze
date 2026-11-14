import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/image_gen/services/image_tag_markup.dart';

void main() {
  group('ImageBlockPayload', () {
    test('reads a legacy single-image result payload', () {
      final payload = ImageBlockPayload.parseResult('/a.png|{"prompt":"cat"}');
      expect(payload.paths, ['/a.png']);
      expect(payload.activeIndex, 0);
      expect(payload.activePath, '/a.png');
      expect(payload.instruction, '{"prompt":"cat"}');
      expect(payload.hasVariants, isFalse);
    });

    test('a single image keeps the legacy spelling when encoded', () {
      expect(
        const ImageBlockPayload(
          paths: ['/a.png'],
          instruction: '{"prompt":"cat"}',
        ).encodeResult(),
        '/a.png|{"prompt":"cat"}',
      );
    });

    test('marks the visible image once a block holds more than one', () {
      const payload = ImageBlockPayload(
        paths: ['/a.png', '/b.png', '/c.png'],
        activeIndex: 1,
        instruction: '{"prompt":"cat"}',
      );
      expect(payload.encodeResult(), '/a.png;;*/b.png;;/c.png|{"prompt":"cat"}');
      final round = ImageBlockPayload.parseResult(payload.encodeResult());
      expect(round.paths, payload.paths);
      expect(round.activeIndex, 1);
      expect(round.activePath, '/b.png');
    });

    test('a pending payload without the marker is a bare instruction', () {
      final payload = ImageBlockPayload.parsePending('{"prompt":"a|b"}');
      expect(payload.paths, isEmpty);
      expect(payload.instruction, '{"prompt":"a|b"}');
      expect(payload.encodePending(), '{"prompt":"a|b"}');
    });

    test('a pending payload carries earlier images behind the marker', () {
      const payload = ImageBlockPayload(
        paths: ['/a.png', '/b.png'],
        activeIndex: 1,
        instruction: '{"prompt":"cat"}',
      );
      expect(payload.encodePending(), '@/a.png;;*/b.png|{"prompt":"cat"}');
      final round = ImageBlockPayload.parsePending(payload.encodePending());
      expect(round.paths, ['/a.png', '/b.png']);
      expect(round.instruction, '{"prompt":"cat"}');
    });
  });

  group('block variants through a regeneration', () {
    test('a finished image is appended and put on screen', () {
      const text = 'x [IMG:GEN:@/a.png|{"prompt":"cat"}] y';
      final out = ImageTagMarkup.replaceTagWithResult(text, 0, '/b.png');
      expect(
        out,
        'x <img data-iig-instruction=\'{"prompt":"cat"}\' '
            "data-iig-variants='/a.png;;/b.png' data-iig-index='1' "
            'src="/b.png"> y',
      );

      final block = ImageTagMarkup.scanImageBlocks(out).single;
      expect(block.paths, ['/a.png', '/b.png']);
      expect(block.activeIndex, 1);
      expect(block.imagePath, '/b.png');
    });

    test('a reset carries the images the block already holds', () {
      const text = '[IMG:RESULT:/a.png;;*/b.png|{"prompt":"cat"}]';
      final pending = ImageTagMarkup.resetImageBlockAt(text, 0);
      expect(pending, '[IMG:GEN:@/a.png;;*/b.png|{"prompt":"cat"}]');

      final finished = ImageTagMarkup.replaceTagWithResult(pending, 0, '/c.png');
      expect(
        finished,
        '<img data-iig-instruction=\'{"prompt":"cat"}\' '
            "data-iig-variants='/a.png;;/b.png;;/c.png' data-iig-index='2' "
            'src="/c.png">',
      );
    });

    test('a failed regeneration keeps the images in the error card', () {
      const text = '[IMG:GEN:@/a.png|{"prompt":"cat"}]';
      final failed = ImageTagMarkup.replaceTagWithError(text, 0, 'boom');
      expect(failed, contains('"variants":"/a.png"'));

      final retried = ImageTagMarkup.resetImageErrorTags(failed);
      expect(ImageTagMarkup.scanImageBlocks(retried).single.paths, ['/a.png']);

      final finished = ImageTagMarkup.replaceTagWithResult(retried, 0, '/b.png');
      expect(
        ImageTagMarkup.scanImageBlocks(finished).single.paths,
        ['/a.png', '/b.png'],
      );
    });

    test('only the addressed block is reset', () {
      const text =
          '[IMG:RESULT:/a.png|{"prompt":"one"}] [IMG:RESULT:/b.png|{"prompt":"two"}]';
      final out = ImageTagMarkup.resetImageBlockAt(text, 1);
      expect(out, '[IMG:RESULT:/a.png|{"prompt":"one"}] [IMG:GEN:@/b.png|{"prompt":"two"}]');
    });
  });

  group('setImageBlockVariant', () {
    const text = 'a [IMG:RESULT:/a.png;;*/b.png;;/c.png|{"prompt":"cat"}] b';

    test('puts another image of the block on screen', () {
      final out = ImageTagMarkup.setImageBlockVariant(text, 0, 2);
      expect(
        out,
        'a <img data-iig-instruction=\'{"prompt":"cat"}\' '
            "data-iig-variants='/a.png;;/b.png;;/c.png' data-iig-index='2' "
            'src="/c.png"> b',
      );
      expect(ImageTagMarkup.scanImageBlocks(out).single.imagePath, '/c.png');
    });

    test('returns the text unchanged for a no-op or a bad index', () {
      expect(ImageTagMarkup.setImageBlockVariant(text, 0, 1), text);
      expect(ImageTagMarkup.setImageBlockVariant(text, 0, 7), text);
      expect(ImageTagMarkup.setImageBlockVariant(text, 3, 0), text);
      expect(
        ImageTagMarkup.setImageBlockVariant('[IMG:GEN:{"prompt":"x"}]', 0, 0),
        '[IMG:GEN:{"prompt":"x"}]',
      );
    });
  });

  group('rewriteResultPaths with variants', () {
    test('resolves every image of the block', () {
      final out = ImageTagMarkup.rewriteResultPaths(
        '[IMG:RESULT:/a.png;;*/b.png|{"prompt":"cat"}]',
        (path) => 'served:$path',
      );
      expect(
        out,
        '[IMG:RESULT:served:/a.png;;*served:/b.png|{"prompt":"cat"}]',
      );
    });

    test('drops an image that cannot be served and keeps the rest', () {
      final out = ImageTagMarkup.rewriteResultPaths(
        '[IMG:RESULT:/blocked.png;;*/b.png|{}]',
        (path) => path == '/blocked.png' ? null : 'served:$path',
      );
      expect(out, '[IMG:RESULT:served:/b.png|{}]');
    });

    test('drops the tag when nothing can be served', () {
      expect(
        ImageTagMarkup.rewriteResultPaths(
          'x [IMG:RESULT:/a.png;;*/b.png|{}] y',
          (_) => null,
        ),
        'x  y',
      );
    });
  });

  group('context images', () {
    test('only the visible image of a block is offered as context', () {
      expect(
        ImageTagMarkup.extractImageResultPaths(
          '[IMG:RESULT:/a.png;;*/b.png|{}] [IMG:RESULT:/c.png]',
        ),
        ['/b.png', '/c.png'],
      );
    });
  });
}
