import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/extensions/services/blocks/block_image_rerun_queue.dart';
import 'package:glaze_flutter/features/image_gen/services/image_tag_markup.dart';

// Issue #839: an ext block's pictures must not be lost to a second redraw tap
// or to regenerating the block as a whole.
void main() {
  group('ImageTagMarkup.carryImagesFrom', () {
    const previous =
        '<p>old</p>'
        "<img data-iig-instruction='{\"prompt\":\"old cat\"}' "
        "data-iig-variants='generated/a.png;;generated/b.png' "
        "data-iig-index='1' src=\"generated/b.png\">";

    test('a new pending element carries the images the block had', () {
      const fresh =
          "<p>new</p><img data-iig-instruction='{\"prompt\":\"new [cat]\"}' "
          'src="[IMG:GEN]">';
      final carried = ImageTagMarkup.carryImagesFrom(fresh, previous);

      final blocks = ImageTagMarkup.scanImageBlocks(carried);
      expect(blocks, hasLength(1));
      expect(blocks.single.kind, ImageBlockKind.pending);
      expect(blocks.single.paths, ['generated/a.png', 'generated/b.png']);
      // The new prompt is kept, `]` and all: the element spelling stays.
      expect(blocks.single.instruction, '{"prompt":"new [cat]"}');
      expect(carried, startsWith('<p>new</p><img '));

      // Drawing it adds the new picture after the old ones.
      final drawn = ImageTagMarkup.replaceTagWithResult(
        carried,
        0,
        'generated/c.png',
      );
      final result = ImageTagMarkup.scanImageBlocks(drawn).single;
      expect(result.kind, ImageBlockKind.result);
      expect(result.paths, [
        'generated/a.png',
        'generated/b.png',
        'generated/c.png',
      ]);
      expect(result.imagePath, 'generated/c.png');
    });

    test('a bracket tag carries them too', () {
      final carried = ImageTagMarkup.carryImagesFrom(
        '[IMG:GEN:{"prompt":"dog"}]',
        previous,
      );
      final block = ImageTagMarkup.scanImageBlocks(carried).single;
      expect(block.paths, ['generated/a.png', 'generated/b.png']);
      expect(block.instruction, '{"prompt":"dog"}');
    });

    test('blocks are matched by position; extra new ones start empty', () {
      const fresh = '[IMG:GEN:{"prompt":"one"}] [IMG:GEN:{"prompt":"two"}]';
      final blocks = ImageTagMarkup.scanImageBlocks(
        ImageTagMarkup.carryImagesFrom(fresh, previous),
      );
      expect(blocks[0].paths, ['generated/a.png', 'generated/b.png']);
      expect(blocks[1].paths, isEmpty);
    });

    test('nothing to carry leaves the new content untouched', () {
      const fresh =
          '<img data-iig-instruction=\'{"prompt":"x"}\' src="[IMG:GEN]">';
      expect(ImageTagMarkup.carryImagesFrom(fresh, ''), fresh);
      expect(ImageTagMarkup.carryImagesFrom(fresh, '<p>no images</p>'), fresh);
      expect(
        ImageTagMarkup.carryImagesFrom('<p>none</p>', previous),
        '<p>none</p>',
      );
    });
  });

  group('BlockImageRerunQueue', () {
    test(
      'a second redraw of the same picture is dropped while one runs',
      () async {
        final queue = BlockImageRerunQueue();
        final gate = Completer<void>();
        var runs = 0;

        final first = queue.run('row', null, () async {
          runs++;
          await gate.future;
        });
        final second = await queue.run('row', null, () async => runs++);

        expect(second, isFalse);
        expect(queue.isBusy('row'), isTrue);
        gate.complete();
        expect(await first, isTrue);
        expect(runs, 1);
        expect(queue.isBusy('row'), isFalse);

        // Once it is done the same picture can be redrawn again.
        expect(await queue.run('row', null, () async => runs++), isTrue);
        expect(runs, 2);
      },
    );

    test(
      'redraws of other pictures of the row wait for the running one',
      () async {
        final queue = BlockImageRerunQueue();
        final gate = Completer<void>();
        final order = <String>[];

        final first = queue.run('row', 0, () async {
          order.add('0 start');
          await gate.future;
          order.add('0 end');
        });
        final second = queue.run('row', 1, () async => order.add('1'));
        final other = queue.run('other', 0, () async => order.add('other'));

        await other;
        expect(order, ['0 start', 'other']);
        gate.complete();
        await Future.wait([first, second]);
        expect(order, ['0 start', 'other', '0 end', '1']);
      },
    );

    test('a failing redraw does not block the ones behind it', () async {
      final queue = BlockImageRerunQueue();
      final failed = queue.run('row', 0, () async => throw StateError('x'));
      final next = queue.run('row', 1, () async {});
      await expectLater(failed, throwsStateError);
      expect(await next, isTrue);
      expect(queue.isBusy('row'), isFalse);
    });
  });
}
