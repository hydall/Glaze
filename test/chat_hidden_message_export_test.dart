// Hidden messages survive a chat export and come back hidden.
//
// The JSONL export used to skip every hidden message outright, so a chat
// exported from Glaze reached SillyTavern/Tavo with those messages missing
// entirely — nothing to "see", hidden or otherwise. SillyTavern has no hidden
// flag of its own: `/hide` sets `is_system` on the message and the prompt
// builder drops every `is_system` line, so that flag is where `isHidden` has
// to land. `extra.glazeHidden` / `extra.glazeRole` keep a Glaze -> Glaze round
// trip lossless, since `is_system` alone cannot say which of the two states it
// stands for.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/services/chat_import_export.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('glaze_hidden_export_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Future<List<Map<String, dynamic>>> exportMessages(
    List<ChatMessage> messages,
  ) async {
    final result = await exportChatAsJsonl(
      session: ChatSession(
        id: 's1',
        characterId: 'c1',
        sessionIndex: 0,
        messages: messages,
      ),
      character: const Character(id: 'c1', name: 'Alice'),
      outputDir: tempDir.path,
      userName: 'User',
    );
    final lines = await File(result.filePath).readAsLines();
    return lines
        .skip(1)
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .toList();
  }

  /// Exports [messages] and imports the file back, as a user round-tripping a
  /// chat through the export.
  Future<List<ChatMessage>> roundTrip(List<ChatMessage> messages) async {
    final exported = await exportMessages(messages);
    final content = exported.map(jsonEncode).join('\n');
    return importChatFromJsonlString(content).messages;
  }

  const conversation = [
    ChatMessage(id: 'u1', role: 'user', content: 'visible ask'),
    ChatMessage(
      id: 'a1',
      role: 'assistant',
      content: 'hidden reply',
      isHidden: true,
    ),
    ChatMessage(
      id: 'u2',
      role: 'user',
      content: 'hidden ask',
      isHidden: true,
    ),
    ChatMessage(id: 's1', role: 'system', content: 'a system note'),
    ChatMessage(id: 'a2', role: 'assistant', content: 'visible reply'),
  ];

  test('a hidden message is exported instead of being dropped', () async {
    final exported = await exportMessages(conversation);

    expect(exported.length, conversation.length);
    expect(
      exported.map((m) => m['mes']),
      ['visible ask', 'hidden reply', 'hidden ask', 'a system note',
        'visible reply'],
    );
  });

  test('a hidden message is marked the way SillyTavern marks one', () async {
    final exported = await exportMessages(conversation);

    // `is_system` is the marker, on the hidden assistant message...
    expect(exported[1]['is_system'], isTrue);
    expect(exported[1]['is_user'], isFalse);
    // ...and on the hidden user one, which keeps `is_user` as SillyTavern does.
    expect(exported[2]['is_system'], isTrue);
    expect(exported[2]['is_user'], isTrue);

    // A visible message carries neither.
    expect(exported[0]['is_system'], isFalse);
    expect(exported[4]['is_system'], isFalse);
  });

  test('the round trip keeps hidden state and role', () async {
    final imported = await roundTrip(conversation);

    expect(imported.length, conversation.length);
    for (var i = 0; i < conversation.length; i++) {
      expect(imported[i].content, conversation[i].content, reason: 'content $i');
      expect(imported[i].role, conversation[i].role, reason: 'role $i');
      expect(
        imported[i].isHidden,
        conversation[i].isHidden,
        reason: 'isHidden $i',
      );
    }
  });

  test('a system-role message does not come back hidden', () async {
    final imported = await roundTrip(conversation);

    final systemMessage = imported.firstWhere((m) => m.role == 'system');
    expect(systemMessage.content, 'a system note');
    expect(systemMessage.isHidden, isFalse);
  });

  test('a foreign is_system line imports as hidden', () async {
    // A SillyTavern/Tavo file: `is_system` and nothing else. `is_system` there
    // means "kept out of the prompt", which is our isHidden — importing it as
    // a plain system-role message sent it to the model.
    final content = [
      jsonEncode({'user_name': 'User', 'chat_metadata': <String, dynamic>{}}),
      jsonEncode({
        'name': 'Alice',
        'is_user': false,
        'is_system': true,
        'mes': 'hidden by /hide',
      }),
      jsonEncode({
        'name': 'User',
        'is_user': true,
        'is_system': true,
        'mes': 'hidden user turn',
      }),
      jsonEncode({
        'name': 'Alice',
        'is_user': false,
        'is_system': false,
        'mes': 'visible',
      }),
    ].join('\n');

    final imported = importChatFromJsonlString(content).messages;

    expect(imported.length, 3);
    expect(imported[0].isHidden, isTrue);
    expect(imported[0].role, 'system');
    // `is_user` outranks `is_system` — this is a hidden user turn, not a
    // system message.
    expect(imported[1].isHidden, isTrue);
    expect(imported[1].role, 'user');
    expect(imported[2].isHidden, isFalse);
    expect(imported[2].role, 'assistant');
  });
}
