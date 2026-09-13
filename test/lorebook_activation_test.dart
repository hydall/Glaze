import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/lorebook_activation.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';

void main() {
  // `enabled: false` on purpose. It is the Global switch, and
  // `activeLorebooksFor` honours it on its own — left at its default (`true`)
  // every case below would pass through that branch and prove nothing about
  // the scope it claims to be testing.
  const book = Lorebook(id: 'book', name: 'Book', enabled: false);

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
          enabled: false,
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

  test('a book bound to one character stays out of every other chat', () {
    // What importing a character *with* its lorebooks produces: the book is
    // scoped to that character and activated for it, and nothing else.
    const attached = Lorebook(
      id: 'attached',
      name: 'World Lore',
      enabled: false,
      activationScope: 'character',
      activationTargetId: 'imported-char',
    );

    final own = activeLorebooksFor(
      lorebooks: const [attached],
      charId: 'imported-char',
      charWorld: null,
      chatId: 'session-1',
      activations: const LorebookActivations(
        character: {
          'imported-char': ['attached'],
        },
      ),
    );
    expect(own, [attached]);

    final somebodyElse = activeLorebooksFor(
      lorebooks: const [attached],
      charId: 'other-char',
      charWorld: null,
      chatId: 'session-2',
      activations: const LorebookActivations(
        character: {
          'imported-char': ['attached'],
        },
      ),
    );
    expect(somebodyElse, isEmpty);
  });

  test('the Global switch reaches every chat even while pinned', () {
    // The reason the `enabled` branch is not gated on the scope fields: those
    // are a denormalised mirror of the activation map, so a book the user made
    // global *and* pinned to a character carries a character scope too.
    // Requiring the scope to match would take the global half away.
    const pinned = Lorebook(
      id: 'pinned',
      name: 'House Rules',
      activationScope: 'character',
      activationTargetId: 'favourite-char',
    );

    final elsewhere = activeLorebooksFor(
      lorebooks: const [pinned],
      charId: 'other-char',
      charWorld: null,
      chatId: 'session-2',
      activations: const LorebookActivations(
        character: {
          'favourite-char': ['pinned'],
        },
      ),
    );

    expect(elsewhere, [pinned]);
  });
}
