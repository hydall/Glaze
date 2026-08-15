import 'dart:typed_data';

import '../models/api_config.dart';
import '../models/character.dart';
import '../models/chat_message.dart';
import '../models/lorebook.dart';
import '../models/memory_book.dart';
import '../models/persona.dart';
import '../models/preset.dart';
import '../models/studio_config.dart';

abstract class SyncCharacterStore {
  Future<List<Character>> getAll();
  Future<Character?> getById(String id);
  Future<void> put(Character c);
  Future<void> delete(String id);
}

abstract class SyncChatStore {
  Future<List<SessionMetadata>> getAllSessionMetadata();
  Future<ChatSession?> getById(String id);
  Future<void> put(ChatSession s);
  Future<void> delete(String id);
}

abstract class SyncPersonaStore {
  Future<List<Persona>> getAll();
  Future<Persona?> getById(String id);
  Future<void> put(Persona p);
  Future<void> delete(String id);
}

abstract class SyncPresetStore {
  Future<List<Preset>> getAll();
  Future<Preset?> getById(String id);
  Future<void> put(Preset p);
  Future<void> delete(String id);
}

abstract class SyncApiConfigStore {
  Future<List<ApiConfig>> getAll();
  Future<ApiConfig?> getById(String id);
  Future<void> put(ApiConfig c);
  Future<void> delete(String id);
}

abstract class SyncLorebookStore {
  Future<List<Lorebook>> getAll();
  Future<Lorebook?> getById(String id);
  Future<void> put(Lorebook l);
  Future<void> delete(String id);
}

abstract class SyncMemoryBookStore {
  Future<List<MemoryBook>> getAll();
  Future<MemoryBook?> getBySessionId(String sessionId);
  Future<void> put(MemoryBook book);
  Future<void> deleteBySessionId(String sessionId);
}

abstract class SyncEmbeddingStore {
  Future<void> deleteBySourceId(String sourceId);
}

abstract class SyncImageStore {
  String? absolutePath(String? relativePath);
  Future<String> saveBytes(
    Uint8List bytes,
    String subfolder,
    String filename,
    String ext,
  );
}

abstract class SyncTrackerSnapshotStore {
  Future<List<String>> getAllSessionIds();
  Future<List<Map<String, dynamic>>> getBySessionId(String sessionId);
  Future<void> deleteBySessionId(String sessionId);
  Future<void> insertRaw(Map<String, dynamic> snapshot);
}

abstract class SyncTrackerValueStore {
  Future<List<String>> getAllSessionIds();
  Future<List<Map<String, dynamic>>> getBySessionId(String sessionId);
  Future<void> deleteBySessionId(String sessionId);
  Future<void> insertRaw(Map<String, dynamic> tracker);
}

abstract class SyncStudioConfigStore {
  Future<List<StudioConfig>> getAll();
  Future<StudioConfig?> getById(String id);
  Future<void> put(StudioConfig config);
  Future<void> delete(String id);
}

abstract class SyncStudioPresetStore {
  Future<List<StudioPreset>> getAll();
  Future<StudioPreset?> getById(String id);
  Future<void> put(StudioPreset preset);
  Future<void> delete(String id);
}

abstract class SyncChatSummaryStore {
  Future<List<String>> getAllSessionIds();
  Future<Map<String, dynamic>?> getBySessionId(String sessionId);
  Future<void> putRaw(Map<String, dynamic> summary);
  Future<void> deleteBySessionId(String sessionId);
}

abstract class SyncCharacterFolderStore {
  Future<Map<String, dynamic>> getAll();
  Future<void> applyAll(Map<String, dynamic> data);
}

abstract class SyncMemoryGraphStore {
  Future<List<String>> getAllSessionIds();
  Future<Map<String, dynamic>?> getBySessionId(String sessionId);
  Future<void> applyBySessionId(String sessionId, Map<String, dynamic> data);
  Future<void> deleteBySessionId(String sessionId);
}

/// Provenance-preserving atomic character facts plus the immutable baseline
/// selected for a chat session. The collection is synced as one payload so a
/// pulled session never gets facts without its source-card evidence.
abstract class SyncCharacterKnowledgeStore {
  Future<List<String>> getAllSessionIds();
  Future<Map<String, dynamic>?> getBySessionId(String sessionId);
  Future<void> applyBySessionId(String sessionId, Map<String, dynamic> data);
  Future<void> deleteBySessionId(String sessionId);
}

/// Merge-only reconciliation and Card Evolution provenance for one session.
/// Implementations must never replace a longer immutable chain with a stale
/// device's shorter copy.
abstract class SyncReconciliationStateStore {
  Future<List<String>> getAllSessionIds();
  Future<Map<String, dynamic>?> getBySessionId(String sessionId);
  Future<Map<String, dynamic>> mergeBySessionId(
    String sessionId,
    Map<String, dynamic> data,
  );
  Future<void> deleteBySessionId(String sessionId);
}
