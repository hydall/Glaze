// A user message stores the persona it was sent as — the id and the name —
// and the chat renders that persona instead of whichever one is active now.
//
// The id is what gets resolved against the live roster, so renaming a persona
// renames its own past messages. The stored name is the snapshot that outlives
// the persona: once it is deleted the message still carries the right name,
// and only its avatar falls back to the initial letter.

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/bridge/chat_message_mapper.dart';

void main() {
  const mara = ChatMessage(
    id: 'u1',
    role: 'user',
    content: 'привет',
    personaId: 'p-mara',
    personaName: 'Mara',
  );

  ChatMessageMapperContext context({
    Map<String, PersonaIdentity> roster = const {},
  }) => ChatMessageMapperContext(
    currentCharName: 'Alice',
    currentPersonaName: 'Nyx',
    isGenerating: false,
    personasById: roster,
  );

  test('a message renders the persona it was sent as, not the active one', () {
    final map = ChatMessageMapper.toMap(
      mara,
      context(
        roster: const {
          'p-mara': PersonaIdentity(
            name: 'Mara',
            avatarUrl: 'file:///mara.png',
          ),
        },
      ),
    );

    expect(map['personaId'], 'p-mara');
    expect(map['personaName'], 'Mara');
    expect(map['displayName'], 'Mara');
    expect(map['avatarUrl'], 'file:///mara.png');
    expect(map.containsKey('avatarFallback'), isFalse);
  });

  test('a renamed persona renames the messages it sent', () {
    final map = ChatMessageMapper.toMap(
      mara,
      context(
        roster: const {
          'p-mara': PersonaIdentity(
            name: 'Mara Vex',
            avatarUrl: 'file:///m.png',
          ),
        },
      ),
    );

    expect(map['displayName'], 'Mara Vex');
    expect(map['personaName'], 'Mara Vex');
  });

  test('a deleted persona keeps its name and loses its avatar', () {
    // Empty roster: the persona is gone. The name stored on the message is all
    // that is left of it, and the renderer must draw the letter rather than
    // borrow the active persona's picture.
    final map = ChatMessageMapper.toMap(mara, context());

    expect(map['displayName'], 'Mara');
    expect(map['personaName'], 'Mara');
    expect(map.containsKey('avatarUrl'), isFalse);
    expect(map['avatarFallback'], isTrue);
  });

  test('a persona with no avatar image also falls back to its letter', () {
    final map = ChatMessageMapper.toMap(
      mara,
      context(roster: const {'p-mara': PersonaIdentity(name: 'Mara')}),
    );

    expect(map['displayName'], 'Mara');
    expect(map.containsKey('avatarUrl'), isFalse);
    expect(map['avatarFallback'], isTrue);
  });

  test(
    'a message sent before personas were stamped follows the active one',
    () {
      const legacy = ChatMessage(id: 'u0', role: 'user', content: 'привет');

      final map = ChatMessageMapper.toMap(legacy, context());

      // No stored persona to pin: the page keeps using the active identity, so
      // neither the avatar nor the fallback flag may appear on the map.
      expect(map['displayName'], 'Nyx');
      expect(map.containsKey('personaId'), isFalse);
      expect(map.containsKey('avatarUrl'), isFalse);
      expect(map.containsKey('avatarFallback'), isFalse);
    },
  );

  test('an assistant message ignores the persona roster', () {
    const reply = ChatMessage(
      id: 'a1',
      role: 'assistant',
      content: 'hi',
      personaId: 'p-mara',
      personaName: 'Mara',
    );

    final map = ChatMessageMapper.toMap(
      reply,
      context(
        roster: const {
          'p-mara': PersonaIdentity(
            name: 'Mara',
            avatarUrl: 'file:///mara.png',
          ),
        },
      ),
    );

    expect(map['displayName'], 'Alice');
    expect(map.containsKey('personaId'), isFalse);
    expect(map.containsKey('avatarUrl'), isFalse);
    expect(map.containsKey('avatarFallback'), isFalse);
  });
}
