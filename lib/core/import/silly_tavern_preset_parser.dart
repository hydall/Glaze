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

/// Canonical ids that are pure insertion points: their text is produced at
/// prompt-assembly time, so whatever the file carries in `content` is dropped.
///
/// These mirror the eight entries flagged `marker: true` in SillyTavern's
/// `chatCompletionDefaultPrompts`. `main`, `nsfw`, `jailbreak` and
/// `enhanceDefinitions` are deliberately absent — SillyTavern treats them as
/// ordinary text prompts (`nsfw` is even labelled "Auxiliary Prompt" in its
/// UI), and preset authors routinely put real content there.
const _markerBlockIds = <String>{
  'chat_history',
  'char_card',
  'char_personality',
  'user_persona',
  'example_dialogue',
  'worldInfoBefore',
  'worldInfoAfter',
  'scenario',
};

/// Ids that map onto a fixed Glaze block. An imported prompt resolving to one
/// of these keeps the id instead of being assigned a fresh random one.
const _canonicalBlockIds = <String>{
  ..._markerBlockIds,
  'memory',
  'summary',
  'authors_note',
  'guided_generation',
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

/// SillyTavern records marker-ness on the prompt object itself, not on a list
/// of known identifiers. A missing field reads as "not a marker" there, so
/// only an explicit `true` counts as one here.
bool _hasMarkerFlag(Map<String, dynamic> json) => json['marker'] == true;

String _rawBlockContent(Map<String, dynamic> json) =>
    (json['content'] as String?) ?? '';

String _normalizeImportedBlockId(
  String rawId,
  String name,
  Map<String, dynamic> json, {
  required bool nameIsAuthoritative,
}) {
  final byId = _stBlockIds[rawId];
  if (byId != null) return byId;

  final byName = _blockNameToId[name];
  if (byName == null) return rawId;

  // In a SillyTavern file the identifier is the real key and the display name
  // is free-form, so a name match is only a hint: a custom prompt that merely
  // happens to be called e.g. "Scenario" must not be swallowed by the scenario
  // insertion point and lose its text. In Glaze's own export there are no
  // identifiers at all — there the name IS the key, so it always wins.
  if (!nameIsAuthoritative &&
      _markerBlockIds.contains(byName) &&
      !_hasMarkerFlag(json) &&
      _rawBlockContent(json).isNotEmpty) {
    return rawId;
  }
  return byName;
}

/// A block is a placeholder when it resolves to one of Glaze's insertion
/// points, or when the file explicitly flags it as a SillyTavern marker.
bool _isMarkerBlock(String normalizedId, Map<String, dynamic> json) =>
    _markerBlockIds.contains(normalizedId) || _hasMarkerFlag(json);

String _normalizeImportedRole(dynamic role) {
  final value = role is String ? role.trim() : '';
  return value.isEmpty ? 'system' : value;
}

Preset parseSillyTavernPreset(Map<String, dynamic> json, String fileName) {
  final blocks = <PresetBlock>[];
  final regexes = <PresetRegex>[];

  final promptsList = json['prompts'] as List<dynamic>? ?? [];
  // Folders come only from the file's own `block_folders` list and a prompt's
  // explicit `folder` reference. Nothing is ever inferred from a block's name
  // or content, so a preset from another frontend imports as the flat list it
  // is, and a file that declares no folders never grows any.
  final blockFolders = _parseBlockFolders(json);
  final folderIds = {for (final folder in blockFolders) folder.id};

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
      final normalizedId = _normalizeImportedBlockId(
        blockName,
        blockName,
        pm,
        nameIsAuthoritative: true,
      );
      final isMarker = _isMarkerBlock(normalizedId, pm);
      final isCanonical = _canonicalBlockIds.contains(normalizedId);
      final isEnabled = pm['enabled'] as bool? ?? true;
      final isStashed = pm['isStashed'] as bool? ?? false;

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
          content: isMarker ? '' : _rawBlockContent(pm),
          enabled: isEnabled,
          isStashed: isStashed,
          isStatic: _staticBlockIds.contains(normalizedId),
          insertionMode: insertionMode,
          depth: depth,
          appendToLastMessage: pm['appendToLastMessage'] as bool? ?? false,
          sendEmptyBlock: pm['sendEmptyBlock'] as bool? ?? false,
          folderId: _declaredFolderRef(pm, folderIds),
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
      final normalizedId = _normalizeImportedBlockId(
        identifier,
        blockName,
        p,
        nameIsAuthoritative: false,
      );
      final isMarker = _isMarkerBlock(normalizedId, p);
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
          content: isMarker ? '' : _rawBlockContent(p),
          enabled: isEnabled,
          isStashed: false,
          isStatic: _staticBlockIds.contains(normalizedId),
          insertionMode: insertionMode,
          depth: depth,
          sendEmptyBlock: p['sendEmptyBlock'] as bool? ?? false,
          folderId: _declaredFolderRef(p, folderIds),
        ),
      );
    }

    for (final p in promptsList) {
      final pm = p as Map<String, dynamic>;
      final identifier = pm['identifier'] as String?;
      if (identifier == null || usedIdentifiers.contains(identifier)) continue;
      usedIdentifiers.add(identifier);

      final blockName = (pm['name'] as String?) ?? identifier;
      final normalizedId = _normalizeImportedBlockId(
        identifier,
        blockName,
        pm,
        nameIsAuthoritative: false,
      );
      final isMarker = _isMarkerBlock(normalizedId, pm);

      final blockJson = Map<String, dynamic>.from(pm);
      blockJson['id'] = normalizedId;
      blockJson['name'] = blockName;
      blockJson['role'] = _normalizeImportedRole(pm['role']);
      blockJson['content'] = isMarker ? '' : (pm['content'] ?? '');
      // Absence from prompt_order is ordering membership, not enabled state.
      blockJson['isStashed'] = true;
      blockJson['folderId'] = _declaredFolderRef(pm, folderIds);

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
      blockFolders: blockFolders,
      regexes: regexes,
      reasoningEnabled:
          json['reasoning'] as bool? ??
          json['reasoning_enabled'] as bool? ??
          false,
      createdAt: currentTimestampSeconds(),
    ),
  );
}

/// Reads the preset's declared folders. Anything without a usable id is
/// skipped, and duplicates collapse to the first entry.
List<PresetBlockFolder> _parseBlockFolders(Map<String, dynamic> json) {
  final raw = json['block_folders'];
  if (raw is! List) return const [];
  final folders = <PresetBlockFolder>[];
  final seen = <String>{};
  for (final entry in raw) {
    if (entry is! Map) continue;
    final map = Map<String, dynamic>.from(entry);
    final id = map['id'];
    if (id is! String || id.isEmpty || !seen.add(id)) continue;
    final name = map['name'];
    final enabled = map['enabled'];
    final exclusive = map['exclusive'];
    folders.add(
      PresetBlockFolder(
        id: id,
        name: name is String && name.trim().isNotEmpty ? name.trim() : id,
        enabled: enabled is bool ? enabled : true,
        exclusive: exclusive is bool ? exclusive : false,
      ),
    );
  }
  return folders;
}

/// A prompt's folder reference, kept only when the preset actually declares
/// that folder — a dangling reference imports as a top-level block.
String? _declaredFolderRef(Map<String, dynamic> prompt, Set<String> declared) {
  final id = prompt['folder'];
  return id is String && declared.contains(id) ? id : null;
}
