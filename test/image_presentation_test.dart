import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/image_recovery_service.dart';
import 'package:glaze_flutter/features/image_gen/services/image_tag_markup.dart';

/// A card that lays its picture out keeps that layout through every state of
/// the image block (INV-IG14).
void main() {
  // The aspect-ratio box of the "Polaroid Diaries" ExtBlocks preset: the
  // picture is pinned over a padding box, so without its style it falls below
  // the box and leaves an empty frame behind.
  const style =
      'position:absolute;top:0;left:0;width:100%;height:100%;object-fit:cover';
  const pending =
      '<div style="position:relative;padding-top:66.3%">'
      '<img data-iig-instruction=\'{"prompt":"a cat"}\' src="[IMG:GEN]" '
      'style="$style" class="photo" onerror="x()">'
      '</div>';

  String resolved(String text) =>
      ImageTagMarkup.replaceTagWithResult(text, 0, 'generated/a.jpg');

  test('the finished element keeps the author\'s presentation', () {
    final done = resolved(pending);
    expect(
      done,
      contains(
        '<img data-iig-instruction=\'{"prompt":"a cat"}\' '
        'src="generated/a.jpg" style="$style" class="photo">',
      ),
    );
    // Handlers and other attributes are not ours to carry.
    expect(done, isNot(contains('onerror')));
    final block = ImageTagMarkup.scanImageBlocks(done).single;
    expect(block.presentation, {'style': style, 'class': 'photo'});
  });

  test('a plain tag gains nothing', () {
    expect(
      ImageTagMarkup.replaceTagWithResult('[IMG:GEN:cat]', 0, 'g/a.jpg'),
      '<img data-iig-instruction=\'{"prompt":"cat"}\' src="g/a.jpg">',
    );
  });

  test('a regeneration keeps the presentation and the earlier image', () {
    final reset = ImageTagMarkup.resetImageBlockAt(resolved(pending), 0);
    expect(reset, contains('src="[IMG:GEN]"'));
    expect(reset, contains('style="$style"'));

    final tag = ImageTagMarkup.scanPendingTags(reset).single;
    expect(tag.presentation['style'], style);
    expect(
      ImageTagMarkup.extractImageGenInstructions(reset).single['prompt'],
      'a cat',
    );

    final again = ImageTagMarkup.replaceTagWithResult(
      reset,
      0,
      'generated/b.jpg',
    );
    final block = ImageTagMarkup.scanImageBlocks(again).single;
    expect(block.paths, ['generated/a.jpg', 'generated/b.jpg']);
    expect(block.imagePath, 'generated/b.jpg');
    expect(block.presentation['style'], style);
  });

  test('switching variants and rewriting paths keep it', () {
    var text = resolved(pending);
    text = ImageTagMarkup.replaceImageBlockWithResult(
      text,
      0,
      'generated/b.jpg',
    );
    text = ImageTagMarkup.setImageBlockVariant(text, 0, 0);
    text = ImageTagMarkup.rewriteResultPaths(text, (path) => '/root/$path');
    final block = ImageTagMarkup.scanImageBlocks(text).single;
    expect(block.imagePath, '/root/generated/a.jpg');
    expect(block.presentation['style'], style);
  });

  test('an error card carries it back to the retried picture', () {
    final failed = ImageTagMarkup.replaceTagWithError(pending, 0, 'boom');
    expect(
      ImageTagMarkup.scanImageBlocks(failed).single.presentation['class'],
      'photo',
    );

    final retried = ImageTagMarkup.resetErrorTags(failed);
    final done = resolved(retried);
    expect(done, contains('src="generated/a.jpg" style="$style"'));
  });

  test('an interrupted generation keeps it on the error card', () {
    final stuck = ImageRecoveryService.cleanStuckImgGenTags(pending);
    final retried = ImageTagMarkup.resetErrorTags(stuck);
    expect(
      ImageTagMarkup.scanPendingTags(retried).single.presentation['style'],
      style,
    );
  });

  test('a bracket in the presentation does not end the error card', () {
    const odd =
        '<img data-iig-instruction=\'{"prompt":"cat"}\' src="[IMG:GEN]" '
        'alt="[cat]">';
    final failed = ImageTagMarkup.replaceTagWithError(odd, 0, 'boom');
    final block = ImageTagMarkup.scanImageBlocks(failed).single;
    expect(block.end, failed.length);
    expect(block.presentation['alt'], '[cat]');
  });

  test('the model still reads only the bare tag (INV-IG12)', () {
    expect(
      ImageTagMarkup.reduceBlocksToInstructions(resolved(pending)),
      contains('[IMG:GEN:{"prompt":"a cat"}]'),
    );
  });
}
