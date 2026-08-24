import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/lorebook_activation.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';

void main() {
  const book = Lorebook(id: 'book', name: 'Book');

  test('character activation applies to every variation in its group', () {
    final active = activeLorebooksFor(
      lorebooks: const [book],
      charId: 'variant',
      charGroupId: 'group',
      charWorld: null,
      chatId: null,
      activations: const LorebookActivations(
        character: {
          'group': ['book'],
        },
      ),
    );

    expect(active, [book]);
  });

  test('legacy activation for a concrete variation remains valid', () {
    final active = activeLorebooksFor(
      lorebooks: const [book],
      charId: 'variant',
      charGroupId: 'group',
      charWorld: null,
      chatId: null,
      activations: const LorebookActivations(
        character: {
          'variant': ['book'],
        },
      ),
    );

    expect(active, [book]);
  });

  test('persisted lorebook target may point at the variation group', () {
    final active = activeLorebooksFor(
      lorebooks: const [
        Lorebook(
          id: 'book',
          name: 'Book',
          activationScope: 'character',
          activationTargetId: 'group',
        ),
      ],
      charId: 'variant',
      charGroupId: 'group',
      charWorld: null,
      chatId: null,
      activations: const LorebookActivations(),
    );

    expect(active, hasLength(1));
  });
}
