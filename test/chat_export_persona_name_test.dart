// A user message names the persona it was sent as when the chat is exported.
//
// The SillyTavern JSONL format puts the sender in each line's `name`, and the
// export used to write one name for every user message — the literal "User",
// since nothing ever passed a persona in. Now that a message stores the persona
// it was sent as, the export writes that, and falls back to the caller's name
// only for the messages that carry none.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/services/chat_import_export.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('glaze_chat_export_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  /// Every exported line after the metadata header, decoded.
  Future<List<Map<String, dynamic>>> exportMessages(
    List<ChatMessage> messages, {
    String userName = 'User',
  }) async {
    final result = await exportChatAsJsonl(
      session: ChatSession(
        id: 's1',
        characterId: 'c1',
        sessionIndex: 0,
        messages: messages,
      ),
      character: const Character(id: 'c1', name: 'Alice'),
      outputDir: tempDir.path,
      userName: userName,
    );
    final lines = await File(result.filePath).readAsLines();
    return lines
        .skip(1)
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .toList();
  }

  test('a user message is exported under the persona that sent it', () async {
    final exported = await exportMessages([
      const ChatMessage(
        id: 'u1',
        role: 'user',
        content: 'привет',
        personaId: 'p-mara',
        personaName: 'Mara',
      ),
      const ChatMessage(id: 'a1', role: 'assistant', content: 'hi'),
    ]);

    expect(exported[0]['name'], 'Mara');
    expect(exported[0]['is_user'], isTrue);
    // The reply is still the character's, persona roster or not.
    expect(exported[1]['name'], 'Alice');
  });

  test('personas are exported per message, not per chat', () async {
    final exported = await exportMessages([
      const ChatMessage(
        id: 'u1',
        role: 'user',
        content: 'first',
        personaId: 'p-mara',
        personaName: 'Mara',
      ),
      const ChatMessage(
        id: 'u2',
        role: 'user',
        content: 'second',
        personaId: 'p-kai',
        personaName: 'Kai',
      ),
    ]);

    expect(exported.map((m) => m['name']), ['Mara', 'Kai']);
  });

  test('a message with no persona falls back to the given name', () async {
    final exported = await exportMessages([
      const ChatMessage(id: 'u1', role: 'user', content: 'привет'),
      const ChatMessage(
        id: 'u2',
        role: 'user',
        content: 'blank',
        personaName: '   ',
      ),
    ], userName: 'Nyx');

    expect(exported.map((m) => m['name']), ['Nyx', 'Nyx']);
  });
}
