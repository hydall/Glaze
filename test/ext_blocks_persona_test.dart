// `{{user}}` in an ext block injected into the prompt names the persona that
// prompt speaks as. It used to read the global persona alone, so a chat bound
// to another persona — by its own binding or its character's — sent blocks
// naming the wrong one.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/state/active_selection_provider.dart';
import 'package:glaze_flutter/features/extensions/services/ext_blocks_prompt_injection.dart';
import 'package:glaze_flutter/features/personas/persona_list_provider.dart';

class _Roster extends PersonaListNotifier {
  @override
  Future<List<Persona>> build() async => const [
    Persona(id: 'p-mara', name: 'Mara'),
    Persona(id: 'p-nyx', name: 'Nyx'),
  ];
}

Future<String?> personaFor(
  PersonaConnections connections, {
  String? charId = 'c-alice',
}) async {
  final container = ProviderContainer(
    overrides: [personaListProvider.overrideWith(_Roster.new)],
  );
  addTearDown(container.dispose);
  await container.read(personaListProvider.future);
  container.read(activePersonaIdProvider.notifier).state = 'p-nyx';
  container.read(personaConnectionsProvider.notifier).state = connections;
  return container
      .read(extBlocksPromptInjectionProvider)
      .resolveMacroContext('s-1', charId)
      .persona;
}

void main() {
  test('an unbound chat names the global persona', () async {
    expect(await personaFor(const PersonaConnections()), 'Nyx');
  });

  test("the character's binding wins over the global persona", () async {
    expect(
      await personaFor(
        const PersonaConnections(character: {'c-alice': 'p-mara'}),
      ),
      'Mara',
    );
  });

  test("the session's binding wins over the character's", () async {
    expect(
      await personaFor(
        const PersonaConnections(
          character: {'c-alice': 'p-nyx'},
          chat: {'s-1': 'p-mara'},
        ),
      ),
      'Mara',
    );
  });

  test('without the character only the session binding applies', () async {
    expect(
      await personaFor(
        const PersonaConnections(character: {'c-alice': 'p-mara'}),
        charId: null,
      ),
      'Nyx',
    );
  });
}
