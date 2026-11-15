import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/image_gen/services/image_tag_markup.dart';

/// A failed redraw of a block that already had a picture keeps the picture
/// (issue #825).
void main() {
  const instruction = '{"prompt":"cat"}';
  final finished = ImageTagMarkup.encodeResultElement(
    const ImageBlockPayload(paths: ['generated/a.png'], instruction: instruction),
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
      const ImageBlockPayload(paths: ['generated/b.png'], instruction: instruction),
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
}
