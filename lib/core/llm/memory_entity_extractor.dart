import '../models/memory_book.dart';
import '../models/memory_graph.dart';
import '../utils/time_helpers.dart';

/// Simplified NER entity extractor (Phase G3). Characters + locations only.
/// No factions/items/concepts/events in MVP.
///
/// The extractor uses deterministic heuristics (no LLM):
/// - Characters: known names, proper nouns, verb adjacency, possessive,
///   vocative, quote attribution.
/// - Locations: suffixes, locative phrases, place nouns.
/// - Alias resolution: first name, honorific strip, nickname patterns.
class MemoryEntityExtractor {
  const MemoryEntityExtractor._();

  static const _locationSuffixes = [
    'street',
    'avenue',
    'road',
    'quarter',
    'district',
    'bridge',
    'tower',
    'castle',
    'keep',
    'hall',
    'inn',
    'tavern',
    'market',
    'square',
    'plaza',
    'gate',
    'wall',
    'harbor',
    'dock',
    'port',
    'forest',
    'woods',
    'river',
    'lake',
    'mountain',
    'valley',
    'cave',
  ];

  static const _placeNouns = [
    'city',
    'town',
    'village',
    'castle',
    'tavern',
    'temple',
    'church',
    'palace',
    'fortress',
    'camp',
    'ship',
    'island',
    'ruins',
    'sanctuary',
  ];

  static const _locativePhrases = [
    'arrived at',
    'here in',
    'left ',
    'entered ',
    'reached ',
    'heading to',
    'going to',
    'returned to',
    'came from',
    'near ',
    'beyond ',
    'outside ',
  ];

  static const _verbAdjacency = [
    'said',
    'spoke',
    'walked',
    'ran',
    'grabbed',
    'struck',
    'looked',
    'turned',
    'stepped',
    'reached',
    'smiled',
    'laughed',
    'whispered',
    'shouted',
    'nodded',
    'sighed',
    'frowned',
    'stared',
    'approached',
    'attacked',
    'defended',
    'fled',
    'followed',
    'greeted',
    'embraced',
    'extracted',
    'completed',
    'called',
  ];

  static const _honorifics = [
    'mr',
    'mrs',
    'ms',
    'dr',
    'lord',
    'lady',
    'sir',
    'captain',
    'ser',
    'master',
    'mistress',
    'prince',
    'princess',
    'king',
    'queen',
    'father',
    'sister',
    'brother',
    'uncle',
    'aunt',
  ];

  static const _properNounStopwords = {
    'a',
    'an',
    'and',
    'as',
    'at',
    'but',
    'call',
    'contracts',
    'digital',
    'during',
    'encryption',
    'for',
    'from',
    'he',
    'helmet',
    'not',
    'non',
    'reported',
    'routers',
    'she',
    'storm',
    'the',
    'they',
    'unknown',
  };

  /// Extract entities from a [MemoryEntry].
  ///
  /// [knownCharacterNames] is an optional list of character/persona names
  /// from the active character card + persona. These are matched first
  /// to improve precision.
  static List<MemoryEntity> extract(
    MemoryEntry entry, {
    required String sessionId,
    List<String> knownCharacterNames = const [],
  }) {
    final now = currentTimestampSeconds();
    final text = '${entry.title} ${entry.content}';
    final entities = <String, MemoryEntity>{};

    _extractCharacters(
      text,
      entry,
      sessionId,
      knownCharacterNames,
      now,
      entities,
    );
    _extractLocations(text, entry, sessionId, now, entities);

    return entities.values.toList();
  }

  static void _extractCharacters(
    String text,
    MemoryEntry entry,
    String sessionId,
    List<String> knownNames,
    int now,
    Map<String, MemoryEntity> sink,
  ) {
    // 1. Known character names from card + persona
    for (final name in knownNames) {
      if (name.isEmpty || name.length < 2) continue;
      if (text.toLowerCase().contains(name.toLowerCase())) {
        _addEntity(
          sink,
          name,
          'character',
          entry,
          sessionId,
          now,
          aliases: _firstNameAlias(name),
        );
      }
    }

    // 2. Proper nouns: [A-Z][a-z]{2,} appearing 2+ times mid-sentence
    final properNounCounts = <String, int>{};
    final properNounRe = RegExp(r'(?<=[.!?]\s|^\s*)[A-Z][a-z]{2,}');
    for (final match in properNounRe.allMatches(text)) {
      final word = match.group(0)!;
      if (_isRejectedCharacterName(word)) continue;
      properNounCounts[word] = (properNounCounts[word] ?? 0) + 1;
    }

    // Also catch proper nouns after commas/space (vocative, mid-sentence)
    final midSentenceRe = RegExp(r'(?:,\s+|\.\s+)([A-Z][a-z]{2,})');
    for (final match in midSentenceRe.allMatches(text)) {
      final word = match.group(1)!;
      if (_isRejectedCharacterName(word)) continue;
      properNounCounts[word] = (properNounCounts[word] ?? 0) + 1;
    }

    for (final entry_ in properNounCounts.entries) {
      if (entry_.value >= 2) {
        _addEntity(
          sink,
          entry_.key,
          'character',
          entry,
          sessionId,
          now,
          aliases: _firstNameAlias(entry_.key),
        );
      }
    }

    // 3. Verb adjacency: "Name said", "Name walked"
    for (final verb in _verbAdjacency) {
      final re = RegExp(r'([A-Z][a-z]{2,})\s+' + verb + r'\b');
      for (final match in re.allMatches(text)) {
        final name = match.group(1)!;
        if (_isRejectedCharacterName(name)) continue;
        _addEntity(
          sink,
          name,
          'character',
          entry,
          sessionId,
          now,
          aliases: _firstNameAlias(name),
        );
      }
    }

    // 4. Possessive: "Name's eyes/voice/hand"
    final possessiveRe = RegExp(
      r"([A-Z][a-z]{2,})'s\s+(?:eyes|voice|hand|face|heart|body|arm|lips|gaze)",
    );
    for (final match in possessiveRe.allMatches(text)) {
      final name = match.group(1)!;
      if (_isRejectedCharacterName(name)) continue;
      _addEntity(
        sink,
        name,
        'character',
        entry,
        sessionId,
        now,
        aliases: _firstNameAlias(name),
      );
    }

    // 5. Vocative: ", Name, "
    final vocativeRe = RegExp(r',\s+([A-Z][a-z]{2,}),\s+');
    for (final match in vocativeRe.allMatches(text)) {
      final name = match.group(1)!;
      if (_isRejectedCharacterName(name)) continue;
      _addEntity(
        sink,
        name,
        'character',
        entry,
        sessionId,
        now,
        aliases: _firstNameAlias(name),
      );
    }

    // 6. Quote attribution: "...", said Name
    final quoteRe = RegExp(
      r'"[^"]*"\s+(?:said|whispered|shouted|replied)\s+([A-Z][a-z]{2,})',
    );
    for (final match in quoteRe.allMatches(text)) {
      final name = match.group(1)!;
      if (_isRejectedCharacterName(name)) continue;
      _addEntity(
        sink,
        name,
        'character',
        entry,
        sessionId,
        now,
        aliases: _firstNameAlias(name),
      );
    }

    // 7. Honorific strip: "Captain Melina" → "Melina"
    for (final honorific in _honorifics) {
      final re = RegExp(
        r'\b' + honorific + r'\s+([A-Z][a-z]{2,})',
        caseSensitive: false,
      );
      for (final match in re.allMatches(text)) {
        final name = match.group(1)!;
        final fullName = '${_capitalize(honorific)} $name';
        final key = 'character:${_normalizeName(name).toLowerCase()}';
        final existing = sink[key];
        if (existing != null) {
          // Add full name as alias
          if (!existing.aliases.contains(fullName)) {
            sink[key] = existing.copyWith(
              aliases: [...existing.aliases, fullName],
              mentionCount: existing.mentionCount + 1,
            );
          }
        } else {
          _addEntity(
            sink,
            name,
            'character',
            entry,
            sessionId,
            now,
            aliases: [fullName],
          );
        }
      }
    }
  }

  static void _extractLocations(
    String text,
    MemoryEntry entry,
    String sessionId,
    int now,
    Map<String, MemoryEntity> sink,
  ) {
    final lower = text.toLowerCase();

    // 1. Location suffixes: "... Bridge", "... Tower"
    for (final suffix in _locationSuffixes) {
      final re = RegExp(
        r'([A-Z][a-z]+(?:\s+[A-Z][a-z]+)*)\s+' + _capitalize(suffix) + r'\b',
      );
      for (final match in re.allMatches(text)) {
        final name = '${match.group(1)} ${_capitalize(suffix)}';
        if (_locationNameLooksValid(name)) {
          _addEntity(sink, name, 'location', entry, sessionId, now);
        }
      }
    }

    // 2. Locative phrases: "arrived at X"
    for (final phrase in _locativePhrases) {
      final idx = lower.indexOf(phrase);
      if (idx >= 0) {
        final after = text.substring(idx + phrase.length).trim();
        final match = RegExp(
          r'^([A-Z][a-z]+(?:\s+[A-Z][a-z]+)*)',
        ).firstMatch(after);
        if (match != null) {
          final name = match.group(1)!;
          if (_locationNameLooksValid(name)) {
            _addEntity(sink, name, 'location', entry, sessionId, now);
          }
        }
      }
    }

    // 3. Place nouns: "the city", "a tavern"
    for (final noun in _placeNouns) {
      final re = RegExp(r'\b(?:the|a|an)\s+(' + noun + r')\b');
      for (final match in re.allMatches(lower)) {
        _addEntity(
          sink,
          _capitalize(match.group(1)!),
          'location',
          entry,
          sessionId,
          now,
        );
      }
    }
  }

  static void _addEntity(
    Map<String, MemoryEntity> sink,
    String name,
    String entityType,
    MemoryEntry entry,
    String sessionId,
    int now, {
    List<String> aliases = const [],
  }) {
    final normalizedName = _normalizeName(name);
    if (normalizedName.isEmpty) return;
    if (entityType == 'character' && _isRejectedCharacterName(normalizedName)) {
      return;
    }

    final displayName = _displayName(name);
    final key = '$entityType:${normalizedName.toLowerCase()}';
    final existing = sink[key];
    if (existing != null) {
      final mergedAliases = <String>{...existing.aliases, ...aliases}.toList();
      sink[key] = existing.copyWith(
        mentionCount: existing.mentionCount + 1,
        aliases: mergedAliases,
      );
    } else {
      sink[key] = MemoryEntity(
        id: 'entity_${entry.id}_${entityType}_${_entityIdPart(normalizedName)}',
        chatSessionId: sessionId,
        memoryEntryId: entry.id,
        name: displayName,
        entityType: entityType,
        aliases: aliases,
        mentionCount: 1,
        createdAt: now,
        updatedAt: now,
      );
    }
  }

  static bool _isRejectedCharacterName(String name) {
    final normalized = _normalizeName(name).toLowerCase();
    return normalized.length < 3 ||
        _honorifics.contains(normalized) ||
        _properNounStopwords.contains(normalized);
  }

  static bool _locationNameLooksValid(String name) {
    final normalized = _normalizeName(name);
    if (normalized.isEmpty) return false;
    if (normalized.split(' ').length > 3) return false;
    return normalized
        .split(' ')
        .every((part) => part.isNotEmpty && part[0].toUpperCase() == part[0]);
  }

  static String _normalizeName(String name) => name
      .replaceAll(
        RegExp(
          r'[\u0000-\u002C\u002E-\u002F\u003A-\u0040\u005B-\u0060\u007B-\u007F]+',
        ),
        ' ',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String _displayName(String name) => _normalizeName(name);

  static String _entityIdPart(String name) {
    final normalized = name.toLowerCase().replaceAll(RegExp(r'\s+'), '_');
    return normalized.replaceAll(
      RegExp(
        r'[\u0000-\u002C\u002E-\u002F\u003A-\u0040\u005B-\u005E\u0060\u007B-\u007F]+',
      ),
      '_',
    );
  }

  static List<String> _firstNameAlias(String name) {
    final parts = _normalizeName(name).split(' ');
    if (parts.length >= 2 && parts[0].length >= 3) {
      return [parts[0]];
    }
    return const [];
  }

  static String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }
}
