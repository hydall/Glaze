import '../utils/cast_helpers.dart';

enum CharacterCardUpdatePolicy {
  followSource,
  pinnedBaseline,
  askOnChange;

  String get wireName => switch (this) {
    CharacterCardUpdatePolicy.followSource => 'follow_source',
    CharacterCardUpdatePolicy.pinnedBaseline => 'pinned_baseline',
    CharacterCardUpdatePolicy.askOnChange => 'ask_on_change',
  };

  static CharacterCardUpdatePolicy fromWireName(String value) {
    return CharacterCardUpdatePolicy.values.firstWhere(
      (item) => item.wireName == value,
      orElse: () => CharacterCardUpdatePolicy.followSource,
    );
  }
}

/// Session-start source-card evidence. It is immutable after creation; session
/// development is stored separately as [CharacterKnowledgeFact] rows.
class CharacterSessionBaseline {
  const CharacterSessionBaseline({
    required this.chatSessionId,
    required this.characterId,
    required this.baselineCardJson,
    required this.baselineHash,
    this.sourceHashLastSeen = '',
    this.cardUpdatePolicy = CharacterCardUpdatePolicy.followSource,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  final String chatSessionId;
  final String characterId;
  final String baselineCardJson;
  final String baselineHash;
  final String sourceHashLastSeen;
  final CharacterCardUpdatePolicy cardUpdatePolicy;
  final int createdAt;
  final int updatedAt;

  CharacterSessionBaseline copyWith({
    String? chatSessionId,
    String? characterId,
    String? baselineCardJson,
    String? baselineHash,
    String? sourceHashLastSeen,
    CharacterCardUpdatePolicy? cardUpdatePolicy,
    int? createdAt,
    int? updatedAt,
  }) => CharacterSessionBaseline(
    chatSessionId: chatSessionId ?? this.chatSessionId,
    characterId: characterId ?? this.characterId,
    baselineCardJson: baselineCardJson ?? this.baselineCardJson,
    baselineHash: baselineHash ?? this.baselineHash,
    sourceHashLastSeen: sourceHashLastSeen ?? this.sourceHashLastSeen,
    cardUpdatePolicy: cardUpdatePolicy ?? this.cardUpdatePolicy,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  /// Hash only canonical prompt-relevant card text, excluding avatar/UI data.
  static String hashCanonicalCardPayload(Map<String, Object?> payload) {
    final entries = payload.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    final canonical = entries
        .map((entry) => '${entry.key}:${entry.value ?? ''}')
        .join('\n');
    return computeHash(canonical);
  }
}
