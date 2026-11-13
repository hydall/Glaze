import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/shared/theme/tavo_theme_css.dart';

void main() {
  group('splitTavoCss', () {
    test('keeps page rules on the page and moves text rules to content', () {
      final parts = splitTavoCss('''
.tavo-character-bubble {
  background: rgba(0, 0, 0, 0.5);
}
.tavo-message-content {
  padding: 18px;
}
.tavo-message-content p {
  margin-top: 0;
}
.tavo-message-content > * {
  position: relative;
}
.tavo-character-bubble .tavo-message-content q::after {
  content: "”";
}
''');

      expect(parts.page, contains('.tavo-character-bubble'));
      expect(parts.page, contains('.tavo-message-content {'));
      expect(parts.content, contains(':host .glaze-message p'));
      expect(parts.content, contains(':host .glaze-message > *'));
      expect(
        parts.content,
        contains(':host(.char) .glaze-message .chat-quote::after'),
      );
      expect(parts.content, isNot(contains('.tavo-message-content')));
      expect(parts.chrome, isEmpty);
    });

    test('moves composer rules to the chrome sheet', () {
      final parts = splitTavoCss('''
.tavo-composer-shell { border-radius: 15px; }
.tavo-composer-input::placeholder { opacity: 1; }
.tavo-message-content em { color: red; }
''');

      expect(parts.chrome, contains('.tavo-composer-shell'));
      expect(parts.chrome, contains('.tavo-composer-input::placeholder'));
      expect(parts.page, isEmpty);
      expect(parts.content, contains(':host .glaze-message em'));
    });

    test('keeps the role of a nested selector', () {
      final parts = splitTavoCss('''
.tavo-user-bubble .tavo-message-content q,
.tavo-message-content blockquote p {
  color: red;
}
''');

      expect(
        parts.content,
        contains(':host(.user) .glaze-message .chat-quote-text'),
      );
      expect(parts.content, contains(':host .glaze-message blockquote p'));
    });

    test('maps Tavo speech elements onto the Glaze quote classes', () {
      final parts = splitTavoCss('''
.tavo-message-content q,
.tavo-message-content a[href="#speech"] { color: red; }
.tavo-message-content q::after { content: "”"; }
''');

      expect(parts.content, contains('.chat-quote-text'));
      expect(parts.content, contains('.chat-quote::after'));
      expect(parts.content, isNot(contains(' q')));
    });

    test('keeps the legacy .tav- selectors working', () {
      final parts = splitTavoCss(
        '.tav-character-bubble .tav-message-content p { color: red; }',
      );

      expect(parts.content, contains(':host(.char) .glaze-message p'));
    });

    test('rewrites the reasoning summary to the Glaze header', () {
      final parts = splitTavoCss(
        '.tavo-message-reasoning > summary { font-weight: 600; }',
      );

      expect(parts.page, contains('.msg-reasoning-header'));
      expect(parts.page, isNot(contains('summary')));
    });

    test('splits grouping at-rules into all three sheets', () {
      final parts = splitTavoCss('''
@media (min-width: 600px) {
  .tavo-speaker-name { font-size: 18px; }
  .tavo-message-content p { margin: 0; }
  .tavo-composer-shell { padding: 4px; }
}
''');

      expect(parts.page, contains('@media (min-width: 600px)'));
      expect(parts.page, contains('.tavo-speaker-name'));
      expect(parts.content, contains('@media (min-width: 600px)'));
      expect(parts.content, contains(':host .glaze-message p'));
      expect(parts.chrome, contains('@media (min-width: 600px)'));
      expect(parts.chrome, contains('.tavo-composer-shell'));
    });

    test('resolves asset URLs through the callback', () {
      final parts = splitTavoCss(
        '.tavo-message-content { background-image: url("theme/assets/paper.png"); }',
        assetUrl: (path) => path == 'theme/assets/paper.png'
            ? 'data:image/png;base64,AAAA'
            : null,
      );

      expect(parts.page, contains('data:image/png;base64,AAAA'));
      expect(parts.page, isNot(contains('theme/assets')));
    });
  });
}
