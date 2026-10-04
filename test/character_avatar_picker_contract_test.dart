import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'character avatar picker avoids duplicate desktop bytes and previews thumbnail',
    () {
      final editor = File(
        'lib/features/character_list/character_editor_screen.dart',
      ).readAsStringSync();
      final genericEditor = File(
        'lib/shared/widgets/generic_editor.dart',
      ).readAsStringSync();

      expect(
        editor,
        contains('withData: Platform.isAndroid || Platform.isIOS'),
      );
      expect(editor, contains('selected.bytes ??'));
      expect(genericEditor, contains('resolveGlazeThumbnailPath(avatarPath)'));
    },
  );
}
