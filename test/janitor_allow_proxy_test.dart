import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/services/janitor_provider.dart';
import 'package:glaze_flutter/features/catalog/services/janitor_webview_proxy.dart';

void main() {
  group('janitorAllowsProxy', () {
    test('a card locked to JanitorAI reports allow_proxy: false', () {
      expect(janitorAllowsProxy({'allow_proxy': false}), isFalse);
    });

    test('an explicit allow_proxy: true is allowed', () {
      expect(janitorAllowsProxy({'allow_proxy': true}), isTrue);
    });

    // Only an explicit `false` forbids: a card whose metadata never mentions
    // the field must stay extractable, or every older card would be blocked.
    test('metadata without the field is allowed', () {
      expect(janitorAllowsProxy({'name': 'Someone'}), isTrue);
      expect(janitorAllowsProxy(null), isTrue);
    });
  });

  test('the predicted refusal carries JanitorAI\'s own wording', () {
    const refusal = JanitorRefusedException.proxyForbidden();
    expect(refusal.status, 403);
    expect(refusal.message, 'Proxies are forbidden for this character');
    expect(refusal.isProxyForbidden, isTrue);
  });

  test('an unrelated refusal is not read as a proxy lock', () {
    const refusal = JanitorRefusedException(429, 'Too many requests');
    expect(refusal.isProxyForbidden, isFalse);
  });
}
