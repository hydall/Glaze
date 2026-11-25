import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/widgets/variant_picker_sheet.dart';

void main() {
  group('variantPreview', () {
    test('drops reasoning and collapses whitespace', () {
      expect(
        variantPreview('<think>plan</think>\n\nShe  smiled.\nThen left.'),
        'She smiled. Then left.',
      );
    });

    test('cuts a long reply to a short preview', () {
      final preview = variantPreview('a' * 1000);
      expect(preview.length, lessThan(260));
      expect(preview, endsWith('…'));
    });
  });

  group('swipeVariantOptions', () {
    test('the active variation shows the live content', () {
      const m = ChatMessage(
        id: 'a',
        role: 'assistant',
        content: 'edited second',
        swipes: ['first', 'second'],
        swipeId: 1,
      );
      final options = swipeVariantOptions(m);
      expect(options.map((o) => o.text), ['first', 'edited second']);
    });

    test('an inactive variation shows its stored active sub-swipe', () {
      const m = ChatMessage(
        id: 'a',
        role: 'assistant',
        content: 'second',
        swipes: ['raw first', 'second'],
        swipeId: 1,
        swipesMeta: [
          {
            'agentSwipeId': 1,
            'agentSwipes': [
              {'content': 'raw first', 'kind': 'final'},
              {'content': 'cleaned first', 'kind': 'cleaned'},
            ],
          },
          {},
        ],
      );
      expect(swipeVariantOptions(m).first.text, 'cleaned first');
    });

    test('a failed variation is tagged', () {
      const m = ChatMessage(
        id: 'a',
        role: 'assistant',
        content: 'ok',
        swipes: ['boom', 'ok'],
        swipeId: 1,
        swipesMeta: [
          {'isError': true},
          {},
        ],
      );
      final options = swipeVariantOptions(m);
      expect(options[0].tag, 'error');
      expect(options[1].tag, isNull);
    });
  });

  test('agentVariantOptions tags cleaned passes', () {
    const m = ChatMessage(
      id: 'a',
      role: 'assistant',
      content: 'clean',
      agentSwipes: [
        AgentSwipe(content: 'raw'),
        AgentSwipe(content: 'clean', kind: 'cleaned'),
      ],
      agentSwipeId: 1,
    );
    final options = agentVariantOptions(m);
    expect(options.map((o) => o.text), ['raw', 'clean']);
    expect(options.map((o) => o.tag), [null, 'cleaned']);
  });

  test('the wire kind maps to the switcher', () {
    expect(VariantPickerKind.fromWire('swipe'), VariantPickerKind.swipe);
    expect(
      VariantPickerKind.fromWire('agent-swipe'),
      VariantPickerKind.agentSwipe,
    );
    expect(VariantPickerKind.fromWire('greeting'), VariantPickerKind.greeting);
  });
}
