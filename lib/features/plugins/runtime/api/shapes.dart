import '../../../../core/models/character.dart';
import '../../../../core/models/chat_message.dart';
import '../../../../core/models/persona.dart';

/// JSON shapes `glaze.*` hands to plugin code. Ids are opaque strings.

Map<String, Object?> messageJson(
  ChatMessage m, {
  required int index,
  required String characterId,
}) => {
  'id': m.id,
  'index': index,
  'role': m.role,
  'content': m.content,
  'hidden': m.isHidden,
  if (m.role == 'assistant') 'characterId': characterId,
  if (m.personaId != null) 'personaId': m.personaId,
  if (m.reasoning != null && m.reasoning!.isNotEmpty) 'reasoning': m.reasoning,
  if (m.timestamp != null) 'timestamp': m.timestamp,
  'variantCount': m.swipes.isEmpty ? 1 : m.swipes.length,
  'variant': m.swipeId,
  if (m.hasAttachments) 'attachmentCount': m.attachments.length,
};

String characterName(Character c) =>
    c.displayName?.isNotEmpty == true ? c.displayName! : c.name;

String personaName(Persona p) =>
    p.displayName?.isNotEmpty == true ? p.displayName! : p.name;

Map<String, Object?> characterSummary(Character c) => {
  'id': c.id,
  'name': characterName(c),
  'avatar': c.avatarPath,
};

Map<String, Object?> characterJson(Character c) => {
  'id': c.id,
  'name': c.name,
  'displayName': c.displayName,
  'avatar': c.avatarPath,
  'description': c.description ?? '',
  'personality': c.personality ?? '',
  'scenario': c.scenario ?? '',
  'appearance': c.appearance ?? '',
  'firstMessage': c.firstMes ?? '',
  'exampleMessages': c.mesExample ?? '',
  'systemPrompt': c.systemPrompt ?? '',
  'postHistoryInstructions': c.postHistoryInstructions ?? '',
  'creator': c.creator ?? '',
  'creatorNotes': c.creatorNotes ?? '',
  'alternateGreetings': c.alternateGreetings,
  'tags': c.tags,
  'version': c.characterVersion,
  'macroName': c.macroName,
  'createdAt': c.createdAt,
  'updatedAt': c.updatedAt,
};

/// Applies the writable fields of [data] (shape of [characterJson]) to [c].
Character applyCharacterJson(Character c, Map<String, dynamic> data) {
  String? s(String key, String? fallback) =>
      data.containsKey(key) ? data[key]?.toString() : fallback;
  List<String> list(String key, List<String> fallback) => data[key] is List
      ? [for (final x in data[key] as List) x.toString()]
      : fallback;
  return c.copyWith(
    name: s('name', c.name) ?? c.name,
    displayName: s('displayName', c.displayName),
    description: s('description', c.description),
    personality: s('personality', c.personality),
    scenario: s('scenario', c.scenario),
    appearance: s('appearance', c.appearance),
    firstMes: s('firstMessage', c.firstMes),
    mesExample: s('exampleMessages', c.mesExample),
    systemPrompt: s('systemPrompt', c.systemPrompt),
    postHistoryInstructions: s(
      'postHistoryInstructions',
      c.postHistoryInstructions,
    ),
    creator: s('creator', c.creator),
    creatorNotes: s('creatorNotes', c.creatorNotes),
    alternateGreetings: list('alternateGreetings', c.alternateGreetings),
    tags: list('tags', c.tags),
    characterVersion: s('version', c.characterVersion) ?? c.characterVersion,
    macroName: s('macroName', c.macroName),
    updatedAt: DateTime.now().millisecondsSinceEpoch,
  );
}

Map<String, Object?> personaJson(Persona p, {required bool active}) => {
  'id': p.id,
  'name': p.name,
  'displayName': p.displayName,
  'description': p.prompt ?? '',
  'avatar': p.avatarPath,
  'active': active,
};

Persona applyPersonaJson(Persona p, Map<String, dynamic> data) => p.copyWith(
  name: data['name']?.toString() ?? p.name,
  displayName: data.containsKey('displayName')
      ? data['displayName']?.toString()
      : p.displayName,
  prompt: data.containsKey('description')
      ? data['description']?.toString()
      : p.prompt,
);

bool nameMatches(String name, String query, Object? match) => switch (match) {
  'prefix' => name.startsWith(query),
  'suffix' => name.endsWith(query),
  'contains' => name.contains(query),
  _ => name == query,
};
