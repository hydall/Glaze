import '../../core/models/character.dart';
import 'model_tool.dart';

/// One card field the model may write, under its CCv3 `data` name — the
/// names models already know from SillyTavern cards.
class CharacterCardField {
  const CharacterCardField(
    this.key, {
    required this.labelKey,
    required this.description,
    required this.read,
    required this.write,
    this.isList = false,
  });

  final String key;

  /// Translation key of the label the confirmation sheet shows.
  final String labelKey;
  final String description;
  final bool isList;
  final Object Function(Character c) read;
  final Character Function(Character c, Object value) write;

  Map<String, dynamic> get schema => isList
      ? {
          'type': 'array',
          'items': {'type': 'string'},
          'description': description,
        }
      : {'type': 'string', 'description': description};
}

List<String> _list(Object v) => (v as List).cast<String>();

/// Every writable field, in the order the confirmation sheet lists them.
final List<CharacterCardField> characterCardFields = [
  CharacterCardField(
    'name',
    labelKey: 'model_tools_field_name',
    description: 'Character name.',
    read: (c) => c.name,
    write: (c, v) => c.copyWith(name: v as String),
  ),
  CharacterCardField(
    'description',
    labelKey: 'model_tools_field_description',
    description:
        'Main card text: appearance, background, traits. Use {{char}} and '
        '{{user}} placeholders instead of fixed names where it fits.',
    read: (c) => c.description ?? '',
    write: (c, v) => c.copyWith(description: v as String),
  ),
  CharacterCardField(
    'personality',
    labelKey: 'model_tools_field_personality',
    description: 'Short personality summary.',
    read: (c) => c.personality ?? '',
    write: (c, v) => c.copyWith(personality: v as String),
  ),
  CharacterCardField(
    'scenario',
    labelKey: 'model_tools_field_scenario',
    description: 'Setting and circumstances of the roleplay.',
    read: (c) => c.scenario ?? '',
    write: (c, v) => c.copyWith(scenario: v as String),
  ),
  CharacterCardField(
    'first_mes',
    labelKey: 'model_tools_field_first_mes',
    description: 'Opening message the character sends to start a chat.',
    read: (c) => c.firstMes ?? '',
    write: (c, v) => c.copyWith(firstMes: v as String),
  ),
  CharacterCardField(
    'alternate_greetings',
    labelKey: 'model_tools_field_alternate_greetings',
    description: 'Other opening messages the user can swipe to.',
    isList: true,
    read: (c) => c.alternateGreetings,
    write: (c, v) => c.copyWith(alternateGreetings: _list(v)),
  ),
  CharacterCardField(
    'mes_example',
    labelKey: 'model_tools_field_mes_example',
    description:
        'Example dialogue. Each example starts with a line "<START>", then '
        '"{{user}}: ..." and "{{char}}: ..." lines.',
    read: (c) => c.mesExample ?? '',
    write: (c, v) => c.copyWith(mesExample: v as String),
  ),
  CharacterCardField(
    'system_prompt',
    labelKey: 'model_tools_field_system_prompt',
    description: 'Card-specific system prompt. Usually left empty.',
    read: (c) => c.systemPrompt ?? '',
    write: (c, v) => c.copyWith(systemPrompt: v as String),
  ),
  CharacterCardField(
    'post_history_instructions',
    labelKey: 'model_tools_field_post_history_instructions',
    description:
        'Instructions placed after the chat history. Usually left empty.',
    read: (c) => c.postHistoryInstructions ?? '',
    write: (c, v) => c.copyWith(postHistoryInstructions: v as String),
  ),
  CharacterCardField(
    'creator_notes',
    labelKey: 'model_tools_field_creator_notes',
    description: 'Notes for the reader of the card; never sent to the model.',
    read: (c) => c.creatorNotes ?? '',
    write: (c, v) => c.copyWith(creatorNotes: v as String),
  ),
  CharacterCardField(
    'tags',
    labelKey: 'model_tools_field_tags',
    description: 'Library tags.',
    isList: true,
    read: (c) => c.tags,
    write: (c, v) => c.copyWith(tags: _list(v)),
  ),
  CharacterCardField(
    'creator',
    labelKey: 'model_tools_field_creator',
    description: 'Card author.',
    read: (c) => c.creator ?? '',
    write: (c, v) => c.copyWith(creator: v as String),
  ),
  CharacterCardField(
    'character_version',
    labelKey: 'model_tools_field_character_version',
    description: 'Card version string.',
    read: (c) => c.characterVersion,
    write: (c, v) => c.copyWith(characterVersion: v as String),
  ),
];

final Map<String, CharacterCardField> _fieldsByKey = {
  for (final field in characterCardFields) field.key: field,
};

/// JSON Schema properties for every writable field.
Map<String, dynamic> characterFieldsSchema() => {
  for (final field in characterCardFields) field.key: field.schema,
};

/// The card fields of [c], under their CCv3 names.
Map<String, Object> characterCardJson(Character c) => {
  for (final field in characterCardFields) field.key: field.read(c),
};

/// Validates a model-supplied field map: known keys only, strings or string
/// lists as the field expects, and a non-empty name when one is given.
/// [path] prefixes the reported location (`character`, `changes`).
Map<String, Object> parseCharacterFields(
  Object? raw,
  String path, {
  Set<String> passThrough = const {},
}) {
  if (raw is! Map) throw ModelToolError.invalid(path, 'an object', raw);
  final out = <String, Object>{};
  for (final entry in raw.entries) {
    final key = entry.key.toString();
    if (passThrough.contains(key)) continue;
    final field = _fieldsByKey[key];
    if (field == null) {
      throw ModelToolError(
        'invalid_arguments',
        'Unknown field $path.$key',
        details: {'path': '$path.$key', 'allowed': _fieldsByKey.keys.toList()},
      );
    }
    final value = entry.value;
    if (field.isList) {
      if (value is! List || value.any((item) => item is! String)) {
        throw ModelToolError.invalid(
          '$path.$key',
          'an array of strings',
          value,
        );
      }
      out[key] = List<String>.from(value);
    } else {
      if (value is! String) {
        throw ModelToolError.invalid('$path.$key', 'a string', value);
      }
      out[key] = value;
    }
  }
  final name = out['name'];
  if (name is String && name.trim().isEmpty) {
    throw ModelToolError.invalid('$path.name', 'a non-empty string', name);
  }
  return out;
}

/// [c] with [fields] (as returned by [parseCharacterFields]) written over it.
Character applyCharacterFields(Character c, Map<String, Object> fields) {
  var next = c;
  for (final entry in fields.entries) {
    next = _fieldsByKey[entry.key]!.write(next, entry.value);
  }
  return next;
}

/// The field definition for [key], or null for a key outside the card.
CharacterCardField? characterCardField(String key) => _fieldsByKey[key];
