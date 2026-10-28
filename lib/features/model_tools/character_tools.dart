import 'dart:convert';
import 'dart:typed_data';

import '../../core/models/character.dart';
import '../../core/services/character_import_persistence_coordinator.dart';
import '../../core/state/character_provider.dart';
import '../../core/state/db_provider.dart';
import '../character_list/character_import_persistence_provider.dart';
import 'character_card_fields.dart';
import 'character_tool_proposal.dart';
import 'model_tool.dart';

/// The character-library tools, in the order they are offered.
const List<ModelTool> characterTools = [
  ListCharactersTool(),
  GetCharacterTool(),
  CreateCharacterTool(),
  UpdateCharacterTool(),
];

String? _optionalString(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value == null) return null;
  if (value is! String) throw ModelToolError.invalid(key, 'a string', value);
  return value;
}

Future<Character> _requireCharacter(
  ModelToolContext c,
  Object? id,
  String path,
) async {
  if (id is! String || id.trim().isEmpty) {
    throw ModelToolError.invalid(path, 'a character id string', id);
  }
  final character = await c.ref.read(characterRepoProvider).getById(id.trim());
  if (character == null) {
    throw ModelToolError(
      'resource_not_found',
      'No character with id "$id". Use glaze_list_characters to find ids.',
      details: {'path': path},
    );
  }
  return character;
}

String _snippet(String? text, int max) {
  final value = (text ?? '').trim().replaceAll(RegExp(r'\s+'), ' ');
  return value.length <= max ? value : '${value.substring(0, max)}…';
}

class ListCharactersTool extends ModelTool {
  const ListCharactersTool();

  @override
  String get name => 'glaze_list_characters';

  @override
  ModelToolGroup? get group => null;

  @override
  String get description =>
      'Search the user\'s character library by name or tag. Returns ids, '
      'names, tags and a short description excerpt. Call it before creating '
      'a character to avoid a duplicate, and to find the id to edit.';

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'query': {
        'type': 'string',
        'description':
            'Case-insensitive text matched against names and '
            'tags. Omit to list the most recently updated characters.',
      },
      'limit': {
        'type': 'integer',
        'minimum': 1,
        'maximum': 50,
        'description': 'Maximum results, default 20.',
      },
    },
    'additionalProperties': false,
  };

  @override
  Future<Object?> run(ModelToolContext c, Map<String, dynamic> args) async {
    final query = _optionalString(args, 'query')?.trim().toLowerCase() ?? '';
    final rawLimit = args['limit'];
    if (rawLimit != null && rawLimit is! int) {
      throw ModelToolError.invalid('limit', 'an integer', rawLimit);
    }
    final limit = ((rawLimit as int?) ?? 20).clamp(1, 50);
    final all = await c.ref.read(characterRepoProvider).getAll();
    final matches = [
      for (final ch in all)
        if (!ch.hidden &&
            (query.isEmpty ||
                ch.name.toLowerCase().contains(query) ||
                (ch.displayName ?? '').toLowerCase().contains(query) ||
                ch.tags.any((t) => t.toLowerCase().contains(query))))
          ch,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return {
      'total': matches.length,
      'characters': [
        for (final ch in matches.take(limit))
          {
            'id': ch.id,
            'name': ch.name,
            if (ch.id == c.charId) 'isCurrentChat': true,
            'tags': ch.tags,
            'description': _snippet(ch.description, 160),
          },
      ],
    };
  }
}

class GetCharacterTool extends ModelTool {
  const GetCharacterTool();

  @override
  String get name => 'glaze_get_character';

  @override
  ModelToolGroup? get group => null;

  @override
  String get description =>
      'Read a character card from the library: every editable field under '
      'its character-card name. Omit id to read the character of the '
      'current chat.';

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'id': {'type': 'string', 'description': 'Character id.'},
    },
    'additionalProperties': false,
  };

  @override
  Future<Object?> run(ModelToolContext c, Map<String, dynamic> args) async {
    final character = await _requireCharacter(c, args['id'] ?? c.charId, 'id');
    return {
      'id': character.id,
      if (character.id == c.charId) 'isCurrentChat': true,
      ...characterCardJson(character),
    };
  }
}

class CreateCharacterTool extends ModelTool {
  const CreateCharacterTool();

  @override
  String get name => 'glaze_create_character';

  @override
  ModelToolGroup? get group => ModelToolGroup.charactersCreate;

  @override
  String get description =>
      'Add a new character card to the user\'s library. Only call this when '
      'the user asked for a character to be created. The user reviews the '
      'card and must approve it; a rejection is not an error to retry. Write '
      'complete, ready-to-use fields — at least name, description and '
      'first_mes.';

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'character': {
        'type': 'object',
        'properties': {
          ...characterFieldsSchema(),
          'character_book': {
            'type': 'object',
            'description': 'Optional lorebook created with the card.',
            'properties': {
              'name': {'type': 'string'},
              'entries': {
                'type': 'array',
                'items': {
                  'type': 'object',
                  'properties': {
                    'keys': {
                      'type': 'array',
                      'items': {'type': 'string'},
                      'description': 'Words that activate the entry.',
                    },
                    'content': {'type': 'string'},
                    'comment': {
                      'type': 'string',
                      'description': 'Entry title.',
                    },
                    'constant': {
                      'type': 'boolean',
                      'description': 'Always active, regardless of keys.',
                    },
                  },
                  'required': ['keys', 'content'],
                },
              },
            },
            'required': ['entries'],
          },
        },
        'required': ['name', 'description', 'first_mes'],
        'additionalProperties': false,
      },
    },
    'required': ['character'],
    'additionalProperties': false,
  };

  @override
  Future<Object?> run(ModelToolContext c, Map<String, dynamic> args) async {
    final fields = parseCharacterFields(
      args['character'],
      'character',
      passThrough: const {'character_book'},
    );
    if (fields['name'] == null) {
      throw ModelToolError.invalid(
        'character.name',
        'a non-empty string',
        null,
      );
    }
    final book = _parseBook((args['character'] as Map)['character_book']);

    final approved = await c.confirm(
      CharacterToolProposal(
        kind: CharacterProposalKind.create,
        characterName: fields['name']! as String,
        changes: [
          for (final field in characterCardFields)
            if (fields.containsKey(field.key))
              CharacterFieldChange(field: field, after: fields[field.key]!),
        ],
        lorebookName: book?['name'] as String?,
        lorebookEntryCount: (book?['entries'] as List?)?.length ?? 0,
      ),
    );
    _checkApproval(approved, c);

    // The import path, not a bare insert: it builds the lorebook from
    // `character_book` and fills every default a card from a file gets.
    final card = {
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {...fields, 'character_book': ?book},
    };
    final importer = await c.ref.read(characterImporterProvider.future);
    final imported = await importer.importFromBytes(
      Uint8List.fromList(utf8.encode(jsonEncode(card))),
      'card.json',
    );
    final persisted = await c.ref
        .read(characterImportPersistenceCoordinatorProvider)
        .persist(imported);
    switch (persisted) {
      case CharacterImportPersistenceFailure():
        throw ModelToolError(
          'internal_error',
          'Saving the card failed: ${persisted.error}',
        );
      case CharacterImportPersistenceSuccess():
        return {
          'characterId': persisted.character.id,
          'name': persisted.character.name,
          'lorebookId': persisted.lorebook?.id,
        };
    }
  }

  static Map<String, dynamic>? _parseBook(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map) {
      throw ModelToolError.invalid(
        'character.character_book',
        'an object',
        raw,
      );
    }
    final entries = raw['entries'];
    if (entries is! List) {
      throw ModelToolError.invalid(
        'character.character_book.entries',
        'an array',
        entries,
      );
    }
    for (final (i, entry) in entries.indexed) {
      final path = 'character.character_book.entries[$i]';
      if (entry is! Map) throw ModelToolError.invalid(path, 'an object', entry);
      final keys = entry['keys'];
      if (keys is! List || keys.any((k) => k is! String)) {
        throw ModelToolError.invalid('$path.keys', 'an array of strings', keys);
      }
      if (entry['content'] is! String) {
        throw ModelToolError.invalid(
          '$path.content',
          'a string',
          entry['content'],
        );
      }
    }
    final name = raw['name'];
    return {
      if (name is String && name.trim().isNotEmpty) 'name': name.trim(),
      'entries': [
        for (final (i, entry) in entries.cast<Map<dynamic, dynamic>>().indexed)
          {
            'keys': entry['keys'],
            'content': entry['content'],
            'comment': entry['comment'] is String ? entry['comment'] : '',
            'constant': entry['constant'] == true,
            'enabled': true,
            'insertion_order': 100,
            'id': i,
          },
      ],
    };
  }
}

class UpdateCharacterTool extends ModelTool {
  const UpdateCharacterTool();

  @override
  String get name => 'glaze_update_character';

  @override
  ModelToolGroup? get group => ModelToolGroup.charactersEdit;

  @override
  String get description =>
      'Change fields of an existing character card. Only call this when the '
      'user asked for the card to be changed. Pass only the fields that '
      'change; each given field replaces its whole value (read the card with '
      'glaze_get_character first when editing part of a text). The user '
      'reviews the change and must approve it.';

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'id': {'type': 'string', 'description': 'Character id.'},
      'changes': {
        'type': 'object',
        'properties': characterFieldsSchema(),
        'additionalProperties': false,
        'minProperties': 1,
      },
    },
    'required': ['id', 'changes'],
    'additionalProperties': false,
  };

  @override
  Future<Object?> run(ModelToolContext c, Map<String, dynamic> args) async {
    final current = await _requireCharacter(c, args['id'], 'id');
    final changes = parseCharacterFields(args['changes'], 'changes');
    final effective = {
      for (final entry in changes.entries)
        if (!_sameValue(
          characterCardField(entry.key)!.read(current),
          entry.value,
        ))
          entry.key: entry.value,
    };
    if (effective.isEmpty) {
      return {'characterId': current.id, 'updatedFields': const <String>[]};
    }

    final approved = await c.confirm(
      CharacterToolProposal(
        kind: CharacterProposalKind.update,
        characterName: (effective['name'] as String?) ?? current.name,
        changes: [
          for (final field in characterCardFields)
            if (effective.containsKey(field.key))
              CharacterFieldChange(
                field: field,
                before: field.read(current),
                after: effective[field.key]!,
              ),
        ],
      ),
    );
    _checkApproval(approved, c);

    // Applied to the row as it is now, not to the copy shown in the sheet:
    // the user may have edited the card while the sheet was open.
    final updated = await c.ref
        .read(charactersProvider.notifier)
        .mutate(
          current.id,
          (latest) => applyCharacterFields(
            latest,
            effective,
          ).copyWith(updatedAt: DateTime.now().millisecondsSinceEpoch),
        );
    if (updated == null) {
      throw const ModelToolError(
        'resource_not_found',
        'The character was deleted before the change was saved.',
      );
    }
    return {
      'characterId': updated.id,
      'updatedFields': effective.keys.toList(),
    };
  }

  static bool _sameValue(Object a, Object b) => a is List && b is List
      ? a.length == b.length && a.indexed.every((e) => b[e.$1] == e.$2)
      : a == b;
}

void _checkApproval(bool? approved, ModelToolContext c) {
  if (approved == null) {
    throw const ModelToolError(
      'unavailable',
      'The confirmation could not be shown. Tell the user to keep the app '
          'open on screen and ask again.',
    );
  }
  if (!approved) throw _rejected;
  if (c.isAborted()) throw _aborted;
}

const _rejected = ModelToolError(
  'user_rejected',
  'The user declined this change. Do not retry it unless they ask again.',
);

const _aborted = ModelToolError('cancelled', 'The reply was stopped.');
