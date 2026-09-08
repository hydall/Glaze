class CharacterDeletionResult {
  final Set<String> characterIds;
  final Set<String> sessionIds;
  final Set<String> studioConfigSessionIds;
  final Set<String> lorebookIds;

  const CharacterDeletionResult({
    required this.characterIds,
    required this.sessionIds,
    required this.studioConfigSessionIds,
    required this.lorebookIds,
  });
}

abstract class CharacterDeletionStore {
  Future<CharacterDeletionResult> deleteCharacters(Set<String> characterIds);
}
