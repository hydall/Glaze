// A chat speaks as the persona bound to it, then the one bound to its
// character, then the global one. `hasPersonaBinding` is what tells the
// persona list that a pick in that chat has to rebind it: setting only the
// global persona there changed nothing while the list marked the pick active.

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/state/persona_resolution.dart';

void main() {
  const mara = Persona(id: 'p-mara', name: 'Mara');
  const nyx = Persona(id: 'p-nyx', name: 'Nyx');
  const personas = [mara, nyx];
  const chat = (charId: 'c-alice', sessionId: 's-1');

  test('a chat with no binding follows the global persona', () {
    const connections = PersonaConnections();
    expect(hasPersonaBinding(personas, connections, chat), isFalse);
    expect(
      getEffectivePersona(personas, 'c-alice', 's-1', 'p-nyx', connections),
      nyx,
    );
  });

  test('a character binding overrides the global persona', () {
    const connections = PersonaConnections(character: {'c-alice': 'p-mara'});
    expect(hasPersonaBinding(personas, connections, chat), isTrue);
    expect(
      getEffectivePersona(personas, 'c-alice', 's-1', 'p-nyx', connections),
      mara,
    );
  });

  test('a chat binding overrides the character one', () {
    const connections = PersonaConnections(
      character: {'c-alice': 'p-mara'},
      chat: {'s-1': 'p-nyx'},
    );
    expect(hasPersonaBinding(personas, connections, chat), isTrue);
    expect(
      getEffectivePersona(personas, 'c-alice', 's-1', null, connections),
      nyx,
    );
  });

  test('a binding to a deleted persona does not count', () {
    const connections = PersonaConnections(
      character: {'c-alice': 'p-gone'},
      chat: {'s-1': 'p-gone'},
    );
    expect(hasPersonaBinding(personas, connections, chat), isFalse);
  });

  test('another session of the same character is not bound by this one', () {
    const connections = PersonaConnections(chat: {'s-1': 'p-mara'});
    expect(
      hasPersonaBinding(personas, connections, (
        charId: 'c-alice',
        sessionId: 's-2',
      )),
      isFalse,
    );
  });
}
