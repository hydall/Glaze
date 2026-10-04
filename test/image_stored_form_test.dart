import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/constants/image_gen_patterns.dart';
import 'package:glaze_flutter/core/utils/platform_paths.dart';
import 'package:glaze_flutter/features/chat/bridge/chat_webview_environment.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_serialization.dart';
import 'package:glaze_flutter/features/image_gen/services/image_tag_markup.dart';
import 'package:path/path.dart' as p;

/// The stored form of a finished image block (INV-IG9): an `<img>` element
/// whose `src` is the visible image, relative to the Glaze data root.
void main() {
  group('the stored <img data-iig-…> element', () {
    test('a single-image block is one element with a plain src', () {
      const payload = ImageBlockPayload(
        paths: ['generated/a.jpg'],
        instruction: '{"prompt":"cat"}',
      );
      expect(
        ImageTagMarkup.encodeResultElement(payload),
        '<img data-iig-instruction=\'{"prompt":"cat"}\' '
            'src="generated/a.jpg">',
      );
    });

    test('the other images of the block ride along in the attributes', () {
      const payload = ImageBlockPayload(
        paths: ['generated/a.jpg', 'generated/b.jpg'],
        activeIndex: 1,
        instruction: '{"prompt":"cat"}',
      );
      expect(
        ImageTagMarkup.encodeResultElement(payload),
        '<img data-iig-instruction=\'{"prompt":"cat"}\' '
            "data-iig-variants='generated/a.jpg;;generated/b.jpg' "
            "data-iig-index='1' src=\"generated/b.jpg\">",
      );
    });

    test('encode and scan round-trip a block with variants', () {
      const payload = ImageBlockPayload(
        paths: ['generated/a.jpg', 'generated/b.jpg', 'generated/c.jpg'],
        activeIndex: 2,
        instruction: '{"prompt":"cat"}',
      );
      final scanned = ImageTagMarkup.scanResultElements(
        'x ${ImageTagMarkup.encodeResultElement(payload)} y',
      ).single;
      expect(scanned.payload.paths, payload.paths);
      expect(scanned.payload.activeIndex, 2);
      expect(scanned.payload.activePath, 'generated/c.jpg');
      expect(scanned.payload.instruction, '{"prompt":"cat"}');
    });

    test('a quote or an ampersand in the prompt survives the round trip', () {
      const instruction = '{"prompt":"a \'lone\' cat & a <dog>"}';
      const payload = ImageBlockPayload(
        paths: ['generated/a.jpg'],
        instruction: instruction,
      );
      final encoded = ImageTagMarkup.encodeResultElement(payload);
      expect(encoded, isNot(contains("'a 'lone' cat")));
      expect(
        ImageTagMarkup.scanResultElements(encoded).single.payload.instruction,
        instruction,
      );
    });

    test('an element without an image is pending, not a finished block', () {
      const pending =
          '<img data-iig-instruction=\'{"prompt":"cat"}\' src="[IMG:GEN]">';
      expect(ImageTagMarkup.scanResultElements(pending), isEmpty);
      expect(ImageTagMarkup.pendingImageGenTagCount(pending), 1);
      expect(ImgGenPatterns.isPendingIigElement(pending), isTrue);

      final finished = ImageTagMarkup.encodeResultElement(
        const ImageBlockPayload(
          paths: ['generated/a.jpg'],
          instruction: '{"prompt":"cat"}',
        ),
      );
      expect(ImageTagMarkup.pendingImageGenTagCount(finished), 0);
      expect(ImgGenPatterns.isPendingIigElement(finished), isFalse);
    });

    test('an ordinary image in a message is not an image block', () {
      const text = '<img src="generated/a.jpg"> ![alt](https://x/y.png)';
      expect(ImageTagMarkup.scanResultElements(text), isEmpty);
      expect(ImageTagMarkup.scanImageBlocks(text), isEmpty);
    });
  });

  group('blocks of both stored forms in one message', () {
    const text =
        '[IMG:RESULT:/old.png|{"prompt":"one"}] a '
        '<img data-iig-instruction=\'{"prompt":"two"}\' '
        "data-iig-variants='generated/b.jpg;;generated/c.jpg' "
        'data-iig-index=\'1\' src="generated/c.jpg"> b '
        '[IMG:GEN:{"prompt":"three"}]';

    test('are numbered together in document order', () {
      final blocks = ImageTagMarkup.scanImageBlocks(text);
      expect(blocks.map((b) => b.kind), [
        ImageBlockKind.result,
        ImageBlockKind.result,
        ImageBlockKind.pending,
      ]);
      expect(blocks[0].imagePath, '/old.png');
      expect(blocks[1].imagePath, 'generated/c.jpg');
      expect(blocks[1].paths, ['generated/b.jpg', 'generated/c.jpg']);
    });

    test('only the visible image of each is offered as context', () {
      expect(ImageTagMarkup.extractImageResultPaths(text), [
        '/old.png',
        'generated/c.jpg',
      ]);
    });

    test('resetting one leaves the others alone', () {
      final out = ImageTagMarkup.resetImageBlockAt(text, 1);
      expect(
        out,
        contains('[IMG:GEN:@generated/b.jpg;;*generated/c.jpg|'
            '{"prompt":"two"}]'),
      );
      expect(out, contains('[IMG:RESULT:/old.png|{"prompt":"one"}]'));
      expect(out, isNot(contains('data-iig-instruction')));
    });

    test('a legacy block switched to another variant is stored as an element',
        () {
      final out = ImageTagMarkup.setImageBlockVariant(
        '[IMG:RESULT:/a.png;;*/b.png|{"prompt":"cat"}]',
        0,
        0,
      );
      expect(out, startsWith('<img data-iig-instruction='));
      expect(out, contains('src="/a.png"'));
      expect(ImageTagMarkup.scanImageBlocks(out).single.imagePath, '/a.png');
    });

    test('resetErrorTags sends every finished block back to pending', () {
      final out = ImageTagMarkup.resetErrorTags(text);
      expect(out, isNot(contains('data-iig-instruction')));
      expect(out, isNot(contains('[IMG:RESULT')));
      expect(ImageTagMarkup.pendingImageGenTagCount(out), 3);
    });
  });

  group('resolving the images of a stored element', () {
    test('every variant is resolved and the element keeps its form', () {
      final out = ImageTagMarkup.rewriteResultPaths(
        ImageTagMarkup.encodeResultElement(
          const ImageBlockPayload(
            paths: ['generated/a.jpg', 'generated/b.jpg'],
            activeIndex: 1,
            instruction: '{}',
          ),
        ),
        (path) => 'served:$path',
      );
      final payload = ImageTagMarkup.scanResultElements(out).single.payload;
      expect(payload.paths, ['served:generated/a.jpg', 'served:generated/b.jpg']);
      expect(payload.activeIndex, 1);
      expect(out, contains('src="served:generated/b.jpg"'));
    });

    test('the block is dropped when nothing can be served', () {
      final element = ImageTagMarkup.encodeResultElement(
        const ImageBlockPayload(paths: ['generated/a.jpg']),
      );
      final out = ImageTagMarkup.rewriteResultPaths(
        'x $element y',
        (_) => null,
      );
      expect(out, 'x  y');
    });

    test('a resolved element restores to the path it was written with', () {
      const stored = 'generated/imggen_1_0.jpg';
      final original = ImageTagMarkup.encodeResultElement(
        const ImageBlockPayload(paths: [stored], instruction: '{"prompt":"c"}'),
      );
      final resolved = ImageTagMarkup.rewriteResultPaths(
        original,
        (path) => 'http://127.0.0.1:35621/__glaze_file__?path=$path',
      );
      expect(resolved, contains('__glaze_file__'));

      final restored = ImageTagMarkup.rewriteResultPaths(
        resolved,
        restoreChatWebViewLocalFilePath,
      );
      expect(restored, original);
    });
  });

  group('restoreChatWebViewLocalFilePath', () {
    test('unwraps a loopback URL from an app launch that is gone', () {
      expect(
        restoreChatWebViewLocalFilePath(
          'http://127.0.0.1:35621/__glaze_file__'
          '?path=%2Fdata%2FGlaze%2Fgenerated%2Fimggen_1_0.jpg',
        ),
        'generated/imggen_1_0.jpg',
      );
    });

    test('leaves a remote image and a stored relative path alone', () {
      expect(
        restoreChatWebViewLocalFilePath('https://example.com/a.png'),
        'https://example.com/a.png',
      );
      expect(
        restoreChatWebViewLocalFilePath('generated/a.jpg'),
        'generated/a.jpg',
      );
    });
  });

  group('relativeGlazeFilePath', () {
    test('spells a path under a data root relative to it', () {
      expect(
        relativeGlazeFilePath('/data/user/0/app/files/Glaze/generated/a.jpg'),
        'generated/a.jpg',
      );
      expect(
        relativeGlazeFilePath('/home/u/.local/share/Glaze-nightly/avatars/a.png'),
        'avatars/a.png',
      );
    });

    test('leaves a relative path, a URL and an outside path alone', () {
      expect(relativeGlazeFilePath('generated/a.jpg'), 'generated/a.jpg');
      expect(relativeGlazeFilePath('data:image/png;base64,AA'),
          'data:image/png;base64,AA');
      expect(relativeGlazeFilePath('/etc/passwd'), '/etc/passwd');
    });

    test('round-trips against the current data root', () async {
      final base = await getAppDataDir();
      final absolute = p.join(base, 'generated', 'a.jpg');
      final relative = relativeGlazeFilePath(absolute);
      expect(relative, 'generated/a.jpg');
      expect(resolveGlazeFilePath(relative), absolute);
    });
  });

  group('an ext block that generates its image again', () {
    // The rerun used to look for a pending tag, which a block that already has
    // a picture no longer has: the new image was dropped on the floor.
    test('keeps the earlier image and puts the new one on screen', () {
      const source = '<div>Scene</div>[IMG:RESULT:generated/a.jpg|{"p":1}]';
      final blocks = ImageTagMarkup.scanImageBlocks(source);
      expect(blocks, hasLength(1));

      final out = ImageTagMarkup.replaceImageBlockWithResult(
        source,
        0,
        'generated/b.jpg',
      );
      final block = ImageTagMarkup.scanImageBlocks(out).single;
      expect(block.paths, ['generated/a.jpg', 'generated/b.jpg']);
      expect(block.imagePath, 'generated/b.jpg');
      expect(out, startsWith('<div>Scene</div><img data-iig-instruction='));
    });
  });

  group('cloud sync', () {
    test('a finished block is uploaded as the instruction that made it', () {
      final stored = ImageTagMarkup.encodeResultElement(
        const ImageBlockPayload(
          paths: ['generated/a.jpg', 'generated/b.jpg'],
          activeIndex: 1,
          instruction: '{"prompt":"a red dragon"}',
        ),
      );
      final normalized = SyncSerialization.normalizeImageGenContent(
        '<div>Scene</div>$stored',
      );
      expect(normalized, isNot(contains('generated/')));
      expect(normalized, contains('<div>Scene</div>'));
      expect(normalized, contains(r'[IMG:GEN:{"prompt":"a red dragon"}]'));
    });
  });

  group('text coming back from the WebView', () {
    final source = File(
      'lib/features/chat/bridge/chat_bridge_controller.dart',
    ).readAsStringSync();

    // A message the page handed back used to be stored exactly as rendered,
    // loopback URL included — a picture that stayed broken across restarts.
    test('every inbound message text is put into its stored spelling', () {
      for (final call in [
        "onEditSave?.call(id, restoreImgResults(s))",
        "restoreImgResults(data['content'] as String? ?? '')",
        "restoreImgResults(data['text'] as String? ?? '')",
      ]) {
        expect(source, contains(call), reason: call);
      }
    });
  });
}
