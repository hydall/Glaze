class CharacterDeletionResult {
  final Set<String> characterIds;
  final Set<String> sessionIds;
  final Set<String> studioConfigSessionIds;

  /// Character-scoped lorebooks that were detached back to global scope
  /// because the character they pointed at is gone. They are **not** deleted:
  /// the book keeps its entries and stays in the lorebook list.
  final Set<String> detachedLorebookIds;

  const CharacterDeletionResult({
    required this.characterIds,
    required this.sessionIds,
    required this.studioConfigSessionIds,
    required this.detachedLorebookIds,
  });
}

abstract class CharacterDeletionStore {
  Future<CharacterDeletionResult> deleteCharacters(Set<String> characterIds);
}
