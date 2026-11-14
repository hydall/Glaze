import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

Iterable<File> _markdownDocs() sync* {
  yield File('README.md');
  yield File('CLAUDE.md');
  yield* Directory('docs')
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.md'));
}

void main() {
  group('documentation links', () {
    test('docs do not point at removed planning documents', () {
      const removedDocs = [
        'docs/js_extensions_implementation_plan.md',
        'docs/monblant_compat.md',
      ];

      for (final file in _markdownDocs()) {
        final text = file.readAsStringSync();
        for (final removedDoc in removedDocs) {
          expect(
            text,
            isNot(contains(removedDoc)),
            reason: '${file.path} points at removed $removedDoc',
          );
        }
      }
    });

    test('JS extension docs point at canonical architecture and invariants', () {
      final claude = _read('CLAUDE.md');
      expect(claude, contains('docs/ARCHITECTURE.md'));
      expect(claude, contains('docs/INVARIANTS.md'));
      expect(claude, contains('INV-EG1'));
      expect(claude, contains('INV-JS1'));

      final architecture = _read('docs/ARCHITECTURE.md');
      expect(architecture, contains('INV-EG1'));
      expect(architecture, contains('INV-JS1'));
      expect(architecture, contains('assets/chat_webview/bridge/index.js'));
      expect(architecture, contains('assets/chat_webview/renderer/index.js'));
      expect(architecture, contains('assets/chat_webview/formatter/index.js'));
    });

    test('markdown marker guide references active module files', () {
      final guide = _read('docs/markdown-markers.md');
      expect(
        guide,
        contains('assets/chat_webview/formatter/formatter.js'),
      );
      expect(
        guide,
        contains('assets/chat_webview/formatter/text_format.js'),
      );
      expect(
        guide,
        contains('assets/chat_webview/renderer/shadow_style.js'),
      );
    });
  });
}
