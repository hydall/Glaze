import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/image_gen/services/image_tag_markup.dart';

/// A failed redraw of a block that already had a picture keeps the picture
/// (issue #825).
void main() {
  const instruction = '{"prompt":"cat"}';
  final finished = ImageTagMarkup.encodeResultElement(
    const ImageBlockPayload(
      paths: ['generated/a.png'],
      instruction: instruction,
    ),
  );

  String redrawFailed(String text, int blockIndex, String error) {
    final pending = ImageTagMarkup.resetImageBlockAt(text, blockIndex);
    return ImageTagMarkup.replaceTagWithError(pending, 0, error);
  }

  test('puts the finished picture back and returns the error', () {
    final before = '<div>$finished</div>';
    final after = redrawFailed(before, 0, 'HTTP 429');
    expect(after, contains('[IMG:ERROR:'));

    final restored = ImageTagMarkup.restoreFailedRedraws(before, after);
    expect(restored.text, before);
    expect(restored.errors, ['HTTP 429']);
  });

  test('keeps an error card that was already an error before', () {
    final before = ImageTagMarkup.errorTag({
      'error': 'old',
      'instruction': instruction,
    });
    final after = ImageTagMarkup.errorTag({
      'error': 'new',
      'instruction': instruction,
    });
    final restored = ImageTagMarkup.restoreFailedRedraws(before, after);
    expect(restored.text, after);
    expect(restored.errors, isEmpty);
  });

  test('restores only the block that failed', () {
    final second = ImageTagMarkup.encodeResultElement(
      const ImageBlockPayload(
        paths: ['generated/b.png'],
        instruction: instruction,
      ),
    );
    final before = '$finished text $second';
    final newSecond = ImageTagMarkup.encodeResultElement(
      const ImageBlockPayload(
        paths: ['generated/b.png', 'generated/c.png'],
        activeIndex: 1,
        instruction: instruction,
      ),
    );
    final failedFirst = ImageTagMarkup.errorTag({
      'error': 'limit',
      'instruction': instruction,
      'variants': 'generated/a.png',
    });
    final after = '$failedFirst text $newSecond';

    final restored = ImageTagMarkup.restoreFailedRedraws(before, after);
    expect(restored.text, '$finished text $newSecond');
    expect(restored.errors, ['limit']);
  });

  test('leaves a successful redraw alone', () {
    final after = ImageTagMarkup.encodeResultElement(
      const ImageBlockPayload(
        paths: ['generated/a.png', 'generated/b.png'],
        activeIndex: 1,
        instruction: instruction,
      ),
    );
    final restored = ImageTagMarkup.restoreFailedRedraws(finished, after);
    expect(restored.text, after);
    expect(restored.errors, isEmpty);
  });

  group('failedDrawErrors', () {
    test('reports a block that failed again after an earlier failure', () {
      final before = ImageTagMarkup.errorTag({
        'error': 'HTTP 429',
        'instruction': instruction,
      });
      final pending = ImageTagMarkup.resetImageBlockAt(before, 0);
      final drawn = ImageTagMarkup.replaceTagWithError(pending, 0, 'HTTP 429');
      // The card looks the same as before; the failure is still reported.
      expect(ImageTagMarkup.failedDrawErrors(pending, drawn), ['HTTP 429']);
    });

    test('reports a failed redraw of a finished picture', () {
      final pending = ImageTagMarkup.resetImageBlockAt(finished, 0);
      final drawn = ImageTagMarkup.replaceTagWithError(pending, 0, 'boom');
      expect(ImageTagMarkup.failedDrawErrors(pending, drawn), ['boom']);
    });

    test('ignores blocks that were not asked for or succeeded', () {
      final failed = ImageTagMarkup.errorTag({
        'error': 'old',
        'instruction': instruction,
      });
      final text = '$finished $failed';
      expect(ImageTagMarkup.failedDrawErrors(text, text), isEmpty);
      final pending = ImageTagMarkup.resetImageBlockAt(text, 1);
      final drawn = ImageTagMarkup.replaceTagWithResult(
        pending,
        0,
        'generated/new.png',
      );
      expect(ImageTagMarkup.failedDrawErrors(pending, drawn), isEmpty);
    });
  });

  test('a prompt with ] survives a reset of its error card', () {
    const weighted = '{"prompt":"girl, [[masterpiece]], {smile}"}';
    final element =
        "Text <img data-iig-instruction='$weighted' src=\"[IMG:GEN]\"> more";
    final failed = ImageTagMarkup.replaceTagWithError(element, 0, 'HTTP 429');
    final pending = ImageTagMarkup.resetImageBlockAt(failed, 0);

    expect(ImageTagMarkup.extractImageGenInstructions(pending), [
      {'prompt': 'girl, [[masterpiece]], {smile}'},
    ]);
    expect(pending, startsWith('Text '));
    expect(pending, endsWith(' more'));
    expect(ImageTagMarkup.scanImageBlocks(pending), hasLength(1));
  });
}
