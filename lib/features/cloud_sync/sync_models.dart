import '../../core/constants/build_channel.dart';

enum SyncProvider { dropbox, gdrive }

enum SyncStatus { idle, syncing, error, conflict }

enum EntityType {
  character,
  persona,
  chat,
  memoryBook,
  lorebooks,
  apiPresets,
  themePresets,
  themeState,
  localStorage,
  gallery,
  manifest,
}

class SyncManifestEntry {
  final String type;
  final String id;
  final String path;
  final int updatedAt;
  final String hash;
  final bool deleted;
  final String? charId;
  final String? imgId;
  final String? ext;

  const SyncManifestEntry({
    required this.type,
    required this.id,
    required this.path,
    required this.updatedAt,
    required this.hash,
    this.deleted = false,
    this.charId,
    this.imgId,
    this.ext,
  });

  String get key => entryKey(type, id);

  SyncManifestEntry copyWith({
    String? type,
    String? id,
    String? path,
    int? updatedAt,
    String? hash,
    bool? deleted,
    String? charId,
    String? imgId,
    String? ext,
  }) => SyncManifestEntry(
    type: type ?? this.type,
    id: id ?? this.id,
    path: path ?? this.path,
    updatedAt: updatedAt ?? this.updatedAt,
    hash: hash ?? this.hash,
    deleted: deleted ?? this.deleted,
    charId: charId ?? this.charId,
    imgId: imgId ?? this.imgId,
    ext: ext ?? this.ext,
  );

  Map<String, dynamic> toJson() => {
    'type': type,
    'id': id,
    'path': path,
    'updatedAt': updatedAt,
    'hash': hash,
    'deleted': deleted,
    if (charId != null) 'charId': charId,
    if (imgId != null) 'imgId': imgId,
    if (ext != null) 'ext': ext,
  };

  factory SyncManifestEntry.fromJson(Map<String, dynamic> m) =>
      SyncManifestEntry(
        type: m['type'] as String,
        id: m['id'] as String,
        path: m['path'] as String,
        updatedAt: m['updatedAt'] as int,
        hash: m['hash'] as String,
        deleted: m['deleted'] as bool? ?? false,
        charId: m['charId'] as String?,
        imgId: m['imgId'] as String?,
        ext: m['ext'] as String?,
      );
}

class SyncManifest {
  /// Bump when hash/canonicalization changes so push can skip re-uploading
  /// existing cloud files and refresh manifest only.
  ///
  /// Version history:
  ///   4 — baseline before pipeline_settings sync.
  ///   5 — added `pipeline_settings` entity type (per-session pipeline LLM
  ///         settings: cleaner/aux/consolidation config).
  ///   6 — removed `pipeline_settings` entity type. Pipeline settings are now
  ///         a singleton global in SharedPreferences, no longer synced as a
  ///         per-session Drift collection.
  ///   7 — added `tracker_value` entries for live `tracker_rows` / Tracker
  ///         Values, separate from rollback snapshots.
  ///   8 — added `studio_preset` entity type (DB-backed StudioPresetRows).
  ///   9 — added `local_storage` singleton for global PipelineSettings.
  ///  11 — added `character_knowledge` (atomic facts + session baseline).
  ///  12 — added merge-only `reconciliation_state` provenance.
  static const int currentVersion = 12;

  final int version;
  final String deviceId;
  final int? lastSync;
  final int createdAt;
  final Map<String, SyncManifestEntry> entries;

  /// Whether the last cloud push included API/embedding keys in api_presets.
  final bool apiKeysIncluded;

  const SyncManifest({
    this.version = 2,
    required this.deviceId,
    this.lastSync,
    required this.createdAt,
    this.entries = const {},
    this.apiKeysIncluded = false,
  });

  SyncManifest copyWith({
    int? version,
    String? deviceId,
    int? lastSync,
    int? createdAt,
    Map<String, SyncManifestEntry>? entries,
    bool? apiKeysIncluded,
  }) => SyncManifest(
    version: version ?? this.version,
    deviceId: deviceId ?? this.deviceId,
    lastSync: lastSync ?? this.lastSync,
    createdAt: createdAt ?? this.createdAt,
    entries: entries ?? this.entries,
    apiKeysIncluded: apiKeysIncluded ?? this.apiKeysIncluded,
  );

  Map<String, dynamic> toJson() => {
    'version': version,
    'deviceId': deviceId,
    'lastSync': lastSync,
    'createdAt': createdAt,
    'apiKeysIncluded': apiKeysIncluded,
    'entries': entries.map((k, v) => MapEntry(k, v.toJson())),
  };

  factory SyncManifest.fromJson(Map<String, dynamic> m) => SyncManifest(
    version: m['version'] as int? ?? 2,
    deviceId: m['deviceId'] as String? ?? '',
    lastSync: m['lastSync'] as int?,
    createdAt: m['createdAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
    apiKeysIncluded: m['apiKeysIncluded'] as bool? ?? false,
    entries: _parseEntries(m['entries'] as Map<String, dynamic>?),
  );

  static Map<String, SyncManifestEntry> _parseEntries(Map<String, dynamic>? m) {
    if (m == null) return {};
    return m.map(
      (k, v) =>
          MapEntry(k, SyncManifestEntry.fromJson(v as Map<String, dynamic>)),
    );
  }
}

String entryKey(String type, String id) => '$type:$id';

/// Name of the Glaze root folder in the cloud provider.
///
/// Reuses [glazeDataFolderName] so the cloud tree is named exactly like the
/// desktop data folder: `Glaze` on stable, `Glaze-staging` / `Glaze-nightly`
/// elsewhere. Keeping the channels apart matters as soon as two of them are
/// installed side by side and pointed at the same cloud account — otherwise
/// they overwrite each other's entities through a shared manifest.
const String cloudRootFolderName = glazeDataFolderName;

/// Root of the Glaze tree in the cloud provider, as an absolute path.
///
/// Every cloud path in the sync layer is built from this, so the channel split
/// is a single-constant change for Google Drive. Dropbox needs one extra step
/// — see `_channelSubfolder` in `dropbox_adapter.dart`.
const String cloudBase = '/$cloudRootFolderName';

const int maxSyncPayloadBytes = 30 * 1024 * 1024;

String cloudPath(String type, String id) {
  switch (type) {
    case 'character':
      return '$cloudBase/characters/$id.json';
    case 'persona':
      return '$cloudBase/personas/$id.json';
    case 'chat':
      return '$cloudBase/chats/$id.json';
    case 'memory_book':
      return '$cloudBase/memory_books/$id.json';
    case 'extension_preset':
      return '$cloudBase/extension_presets/$id.json';
    case 'extensions_settings':
      return '$cloudBase/extensions_settings.json';
    case 'info_block':
      return '$cloudBase/info_blocks/$id.json';
    case 'tracker_snapshot':
      return '$cloudBase/tracker_snapshots/$id.json';
    case 'tracker_value':
      return '$cloudBase/tracker_values/$id.json';
    case 'studio_config':
      return '$cloudBase/studio_configs/$id.json';
    case 'studio_preset':
      return '$cloudBase/studio_presets/$id.json';
    case 'chat_summary':
      return '$cloudBase/chat_summaries/$id.json';
    case 'character_folders':
      return '$cloudBase/character_folders.json';
    case 'memory_graph':
      return '$cloudBase/memory_graphs/$id.json';
    case 'character_knowledge':
      return '$cloudBase/character_knowledge/$id.json';
    case 'reconciliation_state':
      return '$cloudBase/reconciliation_state/$id.json';
    case 'lorebooks':
      return '$cloudBase/lorebooks.json';
    case 'api_presets':
      return '$cloudBase/api_presets.json';
    case 'theme_presets':
      return '$cloudBase/theme_presets.json';
    case 'ui_themes':
      return '$cloudBase/ui_themes.json';
    case 'theme_state':
      return '$cloudBase/theme_state.json';
    case 'local_storage':
      return '$cloudBase/local_storage.json';
    case 'manifest':
      return '$cloudBase/manifest.json';
    default:
      return '$cloudBase/misc/$id.json';
  }
}

/// Canonical path for comparing manifest entry paths with cloud list_folder results.
/// Dropbox app-folder listings omit the [cloudBase] prefix; GDrive uses full
/// paths. (`DropboxAdapter` strips its own channel sub-folder before returning
/// listings, so both providers reach this function Glaze-root-relative.)
String normalizeCloudSyncPath(String path) {
  var p = path.trim();
  if (p.isEmpty) return p;
  if (p.startsWith('$cloudBase/')) {
    p = p.substring(cloudBase.length);
  } else if (p == cloudBase) {
    p = '/';
  }
  if (!p.startsWith('/')) p = '/$p';
  return p;
}

bool cloudSyncPathExists(Set<String> normalizedPaths, String entryPath) {
  return normalizedPaths.contains(normalizeCloudSyncPath(entryPath));
}

String galleryCloudPath(String charId, String imgId, String ext) =>
    '$cloudBase/gallery/$charId/$imgId.$ext';

String personaAvatarCloudPath(String personaId, String ext) =>
    '$cloudBase/persona_avatars/$personaId/avatar.$ext';

/// Cover image of an LLM preset. Presets themselves travel as the single
/// `theme_presets` entry, so their binaries are keyed by preset id here.
String presetImageCloudPath(String presetId, String ext) =>
    '$cloudBase/preset_images/$presetId/cover.$ext';
