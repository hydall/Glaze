/// Tells a visual novel's chat session from a chat with a character.
///
/// A novel is stored as the only session of a pseudo-character whose id
/// carries [kVnCharacterIdPrefix] and points at no character row. Character
/// ids from `generateId` are bare base-36, so they never carry it.
library;

const String kVnCharacterIdPrefix = 'vn-';

bool isVnCharacterId(String characterId) =>
    characterId.startsWith(kVnCharacterIdPrefix);
