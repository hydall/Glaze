import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/vn/services/vn_script.dart';

void main() {
  group('extractVnScript', () {
    test('takes the fenced script and drops reasoning', () {
      const reply =
          '<think>plan the rooms</think>Here is your game:\n'
          '```vn\n# hall\nroom 8 8\n> Hello\n```\nEnjoy!';
      expect(extractVnScript(reply), '# hall\nroom 8 8\n> Hello');
    });

    test('accepts a bare script', () {
      expect(extractVnScript('\n# a\n> hi\n'), '# a\n> hi');
    });

    test('rejects a reply without a scene line', () {
      expect(extractVnScript('Sorry, I cannot write that.'), isNull);
      expect(extractVnScript('```\n> only narration\n```'), isNull);
    });
  });

  group('buildVnPage', () {
    test('inlines both scripts and escapes a closing script tag', () {
      final page = buildVnPage(
        shell: '<body><!--VN3D_THREE--><!--VN3D_ENGINE--></body>',
        three: 'var a = "</script>";',
        engine: 'run();',
      );
      expect(
        page,
        '<body><script>var a = "<\\/script>";</script>'
        '<script>run();</script></body>',
      );
    });

    test('the bundled shell has both slots', () {
      final shell = File(kVnPageAsset).readAsStringSync();
      expect(
        () => buildVnPage(shell: shell, three: '', engine: ''),
        returnsNormally,
      );
    });
  });

  test('the bundled sample game is a script', () {
    final sample = File(kVnSampleAsset).readAsStringSync();
    expect(extractVnScript(sample), isNotNull);
  });

  test('generation messages carry the spec, premise and language', () {
    final messages = buildVnGenerationMessages(
      spec: 'SPEC',
      premise: 'a haunted library',
      language: 'Russian',
    );
    expect(messages.first, {'role': 'system', 'content': 'SPEC'});
    expect(messages.last['content'], contains('a haunted library'));
    expect(messages.last['content'], contains('Russian'));
  });
}
