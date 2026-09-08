import '../../core/models/preset.dart';
import '../../core/state/global_regex_provider.dart';
import '../utils/id_generator.dart';
import '../utils/time_helpers.dart';
import '../services/preset_defaults.dart';

const _stBlockIds = <String, String>{
  'chatHistory': 'chat_history',
  'charDescription': 'char_card',
  'charPersonality': 'char_personality',
  'personaDescription': 'user_persona',
  'dialogueExamples': 'example_dialogue',
  'worldInfoBefore': 'worldInfoBefore',
  'worldInfoAfter': 'worldInfoAfter',
  'scenario': 'scenario',
  'main': 'main',
  'nsfw': 'nsfw',
};

const _mandatoryBlockIds = <String>{
  'chat_history',
  'char_card',
  'char_personality',
  'user_persona',
  'example_dialogue',
  'worldInfoBefore',
  'worldInfoAfter',
  'scenario',
  'main',
  'nsfw',
};

const _blockNameToId = <String, String>{
  // Chat history
  'Chat History': 'chat_history',
  // Character card
  'charDescription': 'char_card',
  'Char Description': 'char_card',
  'Character Description': 'char_card',
  'Character Card': 'char_card',
  // Character personality
  'charPersonality': 'char_personality',
  'Char Personality': 'char_personality',
  'Character Personality': 'char_personality',
  // User persona
  'personaDescription': 'user_persona',
  'Persona Description': 'user_persona',
  'User Persona': 'user_persona',
  // Dialogue examples
  'dialogueExamples': 'example_dialogue',
  'Chat Examples': 'example_dialogue',
  'Dialogue Examples': 'example_dialogue',
  // World info
  'World Info Before': 'worldInfoBefore',
  'World Info (before)': 'worldInfoBefore',
  'World Info After': 'worldInfoAfter',
  'World Info (after)': 'worldInfoAfter',
  // Scenario
  'Scenario': 'scenario',
  // Main / nsfw
  'Main Prompt': 'main',
  'nsfw': 'nsfw',
  // Other Glaze system blocks
  'Memory Book': 'memory',
  'Summary': 'summary',
  "Author's Note": 'authors_note',
  'Guided Generation': 'guided_generation',
};

const _staticBlockIds = <String>{
  'worldInfoBefore',
  'worldInfoAfter',
  'char_card',
  'char_personality',
  'user_persona',
  'example_dialogue',
  'scenario',
  'chat_history',
  'memory',
  'summary',
  'authors_note',
  'guided_generation',
};

String _normalizeImportedBlockId(String rawId, String name) {
  if (_stBlockIds.containsKey(rawId)) return _stBlockIds[rawId]!;
  if (_blockNameToId.containsKey(name)) return _blockNameToId[name]!;
  return rawId;
}

String _normalizeImportedRole(dynamic role) {
  final value = role is String ? role.trim() : '';
  return value.isEmpty ? 'system' : value;
}

Preset parseSillyTavernPreset(Map<String, dynamic> json, String fileName) {
  final blocks = <PresetBlock>[];
  final regexes = <PresetRegex>[];

  final promptsList = json['prompts'] as List<dynamic>? ?? [];

  // Detect format: Glaze export uses name/role/content/insertion_mode without
  // `identifier`. SillyTavern native uses `identifier` + `prompt_order`.
  final hasIdentifiers = promptsList.any(
    (p) => (p as Map<String, dynamic>)['identifier'] != null,
  );

  if (!hasIdentifiers && promptsList.isNotEmpty) {
    // ── Glaze-export format ────────────────────────────────────────────────
    for (final p in promptsList) {
      final pm = p as Map<String, dynamic>;
      final blockName = (pm['name'] as String?) ?? '';
      final normalizedId = _normalizeImportedBlockId(blockName, blockName);
      final isMandatory = _mandatoryBlockIds.contains(normalizedId);
      final isCanonical = isMandatory || _staticBlockIds.contains(normalizedId);
      final isEnabled = pm['enabled'] as bool? ?? true;

      final rawMode = pm['insertion_mode'] as String?;
      final String insertionMode;
      final int? depth;
      if (rawMode == 'depth') {
        insertionMode = 'depth';
        final d = pm['depth'];
        depth = d is num ? d.toInt() : 4;
      } else {
        insertionMode = rawMode ?? 'relative';
        depth = null;
      }

      blocks.add(
        PresetBlock(
          id: isCanonical ? normalizedId : generateId(),
          name: blockName,
          role: _normalizeImportedRole(pm['role']),
          content: isMandatory ? '' : ((pm['content'] as String?) ?? ''),
          enabled: isEnabled,
          isStatic: _staticBlockIds.contains(normalizedId),
          insertionMode: insertionMode,
          depth: depth,
          isStashed: pm['isStashed'] as bool? ?? false,
          appendToLastMessage: pm['appendToLastMessage'] as bool? ?? false,
        ),
      );
    }
  } else {
    // ── SillyTavern-native format (identifier + prompt_order) ─────────────
    final promptsById = <String, Map<String, dynamic>>{};
    for (final p in promptsList) {
      final id = (p as Map<String, dynamic>)['identifier'] as String?;
      if (id != null) promptsById[id] = p;
    }

    List<Map<String, dynamic>> orderList = [];
    if (json['prompt_order'] is List) {
      final promptOrder = json['prompt_order'] as List<dynamic>;
      Map<String, dynamic>? preferredOrder;
      for (final o in promptOrder) {
        if (o is! Map<String, dynamic>) continue;
        final cid = o['character_id'];
        if (cid == 100001 && (o['order'] as List?)?.isNotEmpty == true) {
          preferredOrder = o;
          break;
        }
      }
      Map<String, dynamic> bestOrder =
          preferredOrder ??
          promptOrder.fold<Map<String, dynamic>?>(null, (prev, current) {
            if (current is! Map<String, dynamic>) return prev;
            final prevLen = (prev?['order'] as List?)?.length ?? 0;
            final currentLen = (current['order'] as List?)?.length ?? 0;
            return currentLen > prevLen ? current : prev;
          }) ??
          {};
      final order = bestOrder['order'] as List<dynamic>? ?? [];
      for (final item in order) {
        if (item is Map<String, dynamic>) orderList.add(item);
      }
    }

    if (orderList.isEmpty) {
      orderList = promptsList
          .map((p) {
            final pm = p as Map<String, dynamic>;
            return {
              'identifier': pm['identifier'],
              'enabled': pm['enabled'] ?? true,
            };
          })
          .toList()
          .cast<Map<String, dynamic>>();
    }

    final usedIdentifiers = <String>{};

    for (final item in orderList) {
      final identifier = item['identifier'] as String?;
      if (identifier == null) continue;
      final p = promptsById[identifier];
      if (p == null) continue;

      usedIdentifiers.add(identifier);

      final blockName = (p['name'] as String?) ?? identifier;
      final normalizedId = _normalizeImportedBlockId(identifier, blockName);
      final isMandatory = _mandatoryBlockIds.contains(normalizedId);
      final isEnabled =
          item['enabled'] as bool? ?? p['enabled'] as bool? ?? true;

      String insertionMode;
      int? depth;
      if (normalizedId == 'chat_history') {
        insertionMode = 'relative';
      } else if (p['injection_position'] == 1) {
        insertionMode = 'depth';
        depth = p['injection_depth'] as int? ?? 4;
      } else {
        insertionMode = 'relative';
      }

      blocks.add(
        PresetBlock(
          id: normalizedId,
          name: blockName,
          role: _normalizeImportedRole(p['role']),
          content: isMandatory ? '' : ((p['content'] as String?) ?? ''),
          enabled: isEnabled,
          isStatic: _staticBlockIds.contains(normalizedId),
          insertionMode: insertionMode,
          depth: depth,
        ),
      );
    }

    for (final p in promptsList) {
      final pm = p as Map<String, dynamic>;
      final identifier = pm['identifier'] as String?;
      if (identifier == null || usedIdentifiers.contains(identifier)) continue;
      usedIdentifiers.add(identifier);

      final blockName = (pm['name'] as String?) ?? identifier;
      final normalizedId = _normalizeImportedBlockId(identifier, blockName);
      final isMandatory = _mandatoryBlockIds.contains(normalizedId);

      final blockJson = Map<String, dynamic>.from(pm);
      blockJson['id'] = normalizedId;
      blockJson['name'] = blockName;
      blockJson['role'] = _normalizeImportedRole(pm['role']);
      blockJson['content'] = isMandatory ? '' : (pm['content'] ?? '');

      if (pm['injection_position'] == 1) {
        blockJson['insertionMode'] = 'depth';
        blockJson['depth'] = pm['injection_depth'] is num
            ? (pm['injection_depth'] as num).toInt()
            : 4;
      } else {
        blockJson['insertionMode'] = 'relative';
      }

      blocks.add(PresetBlock.fromJson(blockJson));
    }
  }

  final stRegexes = json['regexes'] as List<dynamic>?;
  final extRegexes =
      (json['extensions'] as Map<String, dynamic>?)?['regex_scripts']
          as List<dynamic>?;
  final regexSource = extRegexes ?? stRegexes;
  if (regexSource != null) {
    for (int i = 0; i < regexSource.length; i++) {
      final r = regexSource[i] as Map<String, dynamic>;
      final normalized = normalizeJsGlobalRegex(r);
      if (!normalized.containsKey('id')) normalized['id'] = 'imported_r$i';
      if (r['isEnabled'] is bool) {
        normalized['disabled'] = !(r['isEnabled'] as bool);
      }
      regexes.add(PresetRegex.fromJson(normalized));
    }
  }

  return finalizeImportedPreset(
    Preset(
      id: generateId(),
      name: (json['name'] as String?) ?? fileName.replaceAll('.json', ''),
      blocks: blocks,
      regexes: regexes,
      reasoningEnabled:
          json['reasoning'] as bool? ??
          json['reasoning_enabled'] as bool? ??
          false,
      createdAt: currentTimestampSeconds(),
    ),
  );
}
