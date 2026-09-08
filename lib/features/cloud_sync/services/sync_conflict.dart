import '../sync_models.dart';

class SyncConflict {
  final String key;
  final String type;
  final String id;
  final SyncManifestEntry localEntry;
  final SyncManifestEntry cloudEntry;
  final String name;

  const SyncConflict({
    required this.key,
    required this.type,
    required this.id,
    required this.localEntry,
    required this.cloudEntry,
    required this.name,
  });
}

class SyncConflictDetector {
  static bool needsConflict(
    SyncManifestEntry? localEntry,
    SyncManifestEntry cloudEntry,
  ) {
    if (localEntry == null) return false;
    if (localEntry.deleted) return false;
    if (localEntry.hash == cloudEntry.hash) return false;
    // updatedAt == 0 means never edited on this device — prefer cloud pull.
    if (localEntry.updatedAt == 0) return false;
    return localEntry.updatedAt > cloudEntry.updatedAt;
  }

  static String getConflictName(
    String type,
    dynamic localEntity,
    dynamic cloudEntity,
    String id, {
    String? characterName,
  }) {
    switch (type) {
      case 'character':
        return (localEntity?['name'] ?? cloudEntity?['name'] ?? id) as String;
      case 'persona':
        return (localEntity?['name'] ?? cloudEntity?['name'] ?? id) as String;
      case 'chat':
        final idx =
            localEntity?['sessionIndex'] ?? cloudEntity?['sessionIndex'];
        if (characterName != null && idx != null) {
          return '$characterName — Chat #$idx';
        }
        if (characterName != null) return characterName;
        final charId =
            localEntity?['characterId'] ?? cloudEntity?['characterId'];
        if (charId != null && idx != null) return 'Chat #$idx ($charId)';
        if (charId != null) return 'Chat ($charId)';
        return 'Chat $id';
      case 'lorebooks':
        return 'Lorebooks';
      case 'api_presets':
        return 'API Presets';
      case 'theme_presets':
        return 'Prompt Presets';
      case 'ui_themes':
        return 'UI Themes';
      case 'theme_state':
        return 'Theme State';
      case 'local_storage':
        return 'Local Settings';
      case 'studio_config':
        return (localEntity?['profileName'] ?? cloudEntity?['profileName'] ?? id) as String;
      case 'studio_preset':
        return (localEntity?['name'] ?? cloudEntity?['name'] ?? id) as String;
      default:
        return '$type $id';
    }
  }
}
