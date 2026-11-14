import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/image_gen/services/image_tag_markup.dart';

void main() {
  group('ImageTagMarkup image context helpers', () {
    test('normalizeImageResultPayload strips instruction suffix', () {
      expect(
        ImageTagMarkup.normalizeImageResultPayload(r'C:\img\a.png|{"prompt":"x"}'),
        r'C:\img\a.png',
      );
      expect(ImageTagMarkup.normalizeImageResultPayload(r'C:\img\b.png'), r'C:\img\b.png');
    });

    test('collectRecentImageResultPaths scans newest contents first', () {
      const htmlOld =
          '<div>[IMG:RESULT:/old.png|{"prompt":"1"}]</div>';
      const htmlMid = '[IMG:RESULT:/mid.png]';
      const htmlNew =
          '<img src="[IMG:RESULT:/new.png|{}]">';

      final paths = ImageTagMarkup.collectRecentImageResultPaths(
        [htmlNew, htmlMid, htmlOld],
        maxPaths: 3,
      );

      expect(paths, ['/old.png', '/mid.png', '/new.png']);
    });

    test('collectRecentImageResultPaths respects maxPaths', () {
      final paths = ImageTagMarkup.collectRecentImageResultPaths(
        [
          '[IMG:RESULT:/a.png]',
          '[IMG:RESULT:/b.png]',
          '[IMG:RESULT:/c.png]',
        ],
        maxPaths: 2,
      );

      expect(paths, ['/b.png', '/a.png']);
    });
  });
}
