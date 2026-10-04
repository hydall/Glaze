import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows defers native WebView mounting until after a stable frame', () {
    final source = File(
      'lib/features/chat/widgets/chat_webview_surface.dart',
    ).readAsStringSync();

    expect(source, contains('bool _mountNativeView = !Platform.isWindows;'));
    expect(source, contains('WidgetsBinding.instance.addPostFrameCallback'));
    expect(
      source,
      contains('if (mounted) setState(() => _mountNativeView = true)'),
    );
    expect(source, contains('child: _mountNativeView'));
  });
}
