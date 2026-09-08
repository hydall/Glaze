import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/extensions/services/js_script_extractor.dart';

void main() {
  group('JsScriptExtractor', () {
    test('extracts fenced js block', () {
      const raw = '''
Here is the script:

```js
const n = context.messages.length;
return '<p>Messages: ' + n + '</p>';
```
''';
      final code = JsScriptExtractor.extractFromLlmResponse(raw);
      expect(code, contains('context.messages'));
      expect(code, contains('return'));
    });

    test('extracts javascript fence', () {
      const raw = '```javascript\nreturn "ok";\n```';
      expect(JsScriptExtractor.extractFromLlmResponse(raw), 'return "ok";');
    });

    test('falls back to trimmed raw when no fence', () {
      expect(
        JsScriptExtractor.extractFromLlmResponse('return "plain";'),
        'return "plain";',
      );
    });

    test('formatPanelContent escapes plain result', () {
      final html = JsScriptExtractor.formatPanelContent(
        script: 'return "<x>";',
        result: 'Hello & world',
      );
      expect(html, contains('Hello &amp; world'));
      expect(html, contains('return "&lt;x&gt;"'));
    });
  });
}
