import 'character.dart';

/// Removes user-facing creator notes before a character crosses any prompt or
/// model-processing boundary.
Character sanitizeCharacterForPrompt(Character character) => character.copyWith(
  creatorNotes: null,
  extensions: Map<String, dynamic>.unmodifiable(
    _sanitizeMap(character.extensions),
  ),
);

Map<String, dynamic> _sanitizeMap(Map<Object?, Object?> source) {
  final sanitized = <String, dynamic>{};
  for (final entry in source.entries) {
    final key = entry.key.toString();
    if (_isCreatorNotesKey(key)) continue;
    sanitized[key] = _sanitizeValue(entry.value);
  }
  return sanitized;
}

Object? _sanitizeValue(Object? value) {
  if (value is Map) return _sanitizeMap(value);
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_sanitizeValue));
  }
  return value;
}

bool _isCreatorNotesKey(String key) =>
    key.replaceAll(RegExp('[^a-zA-Z]'), '').toLowerCase() == 'creatornotes';
