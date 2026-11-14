import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/image_gen/services/image_tag_markup.dart';

void main() {
  group('ImageTagMarkup.rewriteResultPaths', () {
    test('rewrites the path and keeps the instruction suffix', () {
      final out = ImageTagMarkup.rewriteResultPaths(
        'before [IMG:RESULT:/data/Glaze/generated/a.png|{"prompt":"cat"}] after',
        (path) => 'http://127.0.0.1:1/__glaze_file__?path=$path',
      );
      expect(
        out,
        'before [IMG:RESULT:http://127.0.0.1:1/__glaze_file__'
        '?path=/data/Glaze/generated/a.png|{"prompt":"cat"}] after',
      );
    });

    test('rewrites a payload without an instruction', () {
      final out = ImageTagMarkup.rewriteResultPaths(
        '[IMG:RESULT:/data/Glaze/generated/a.png]',
        (path) => 'served:$path',
      );
      expect(out, '[IMG:RESULT:served:/data/Glaze/generated/a.png]');
    });

    // A `]` in the prompt used to make the tag unmatchable, and the raw
    // filesystem path reached the WebView as `file://…` — a broken image.
    test('resolves the path when the instruction contains a bracket', () {
      final out = ImageTagMarkup.rewriteResultPaths(
        '[IMG:RESULT:/data/Glaze/generated/a.png|{"prompt":"a [tag] girl"}]',
        (path) => 'served:$path',
      );
      expect(out, startsWith('[IMG:RESULT:served:/data/Glaze/generated/a.png|'));
      expect(out, isNot(contains('[IMG:RESULT:/data')));
    });

    test('drops the tag when the path cannot be served', () {
      final out = ImageTagMarkup.rewriteResultPaths(
        'x [IMG:RESULT:/etc/passwd|{"prompt":"cat"}] y',
        (_) => null,
      );
      expect(out, 'x  y');
    });

    test('rewrites every tag in a message', () {
      final out = ImageTagMarkup.rewriteResultPaths(
        '[IMG:RESULT:/a.png] mid [IMG:RESULT:/b.png|{}]',
        (path) => 'served:$path',
      );
      expect(out, '[IMG:RESULT:served:/a.png] mid [IMG:RESULT:served:/b.png|{}]');
    });

    test('leaves pending and error tags alone', () {
      const text = '[IMG:GEN:{"prompt":"cat"}] [IMG:ERROR:{"error":"nope"}]';
      expect(
        ImageTagMarkup.rewriteResultPaths(text, (path) => 'served:$path'),
        text,
      );
    });
  });
}
