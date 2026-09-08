import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../db/app_db.dart';
import '../../state/global_regex_provider.dart';
import '../image_storage_service.dart';
import 'backup_helpers.dart';
import 'js_api_config_importer.dart';
import 'js_character_importer.dart';
import 'js_chat_importer.dart';
import 'js_lorebook_importer.dart';
import 'js_preset_importer.dart';

class JsBackupImporter extends BackupHelpers {
  @override
  final AppDatabase db;
  @override
  final ImageStorageService imageStorage;

  JsBackupImporter(this.db, this.imageStorage);

  Future<void> import(
    Map<String, dynamic> data, {
    void Function(String stage)? onProgress,
  }) async {
    await _clearAllTables();

    final kv = Map<String, dynamic>.from(data['keyvalue'] as Map<dynamic, dynamic>? ?? {});
    final ls = Map<String, dynamic>.from(data['localStorage'] as Map<dynamic, dynamic>? ?? {});

    final characterImporter = JsCharacterImporter(db, imageStorage);
    final lorebookImporter = JsLorebookImporter(db, imageStorage);
    final apiConfigImporter = JsApiConfigImporter(db, imageStorage);
    final chatImporter = JsChatImporter(db, imageStorage);
    final presetImporter = JsPresetImporter(db, imageStorage);

    Future<void> step(String name, String label, Future<void> Function() fn) async {
      onProgress?.call(label);
      try {
        await fn();
      } catch (e, st) {
        throw Exception('[$name] $e\n$st');
      }
    }

    await step('importCharacters', 'Importing characters...', () => characterImporter.importCharacters(data['characters']));
    await step('importPersonas', 'Importing personas...', () => characterImporter.importPersonas(data['personas']));
    await step('importLorebooks', 'Importing lorebooks...', () => lorebookImporter.importLorebooks(kv));
    await step('importCharacterBooks', 'Importing character books...', () => lorebookImporter.importCharacterBooks(data['characters']));
    await step('importApiConfigs', 'Importing API configs...', () => apiConfigImporter.importApiConfigs(kv, ls, data));
    await step('importLorebookSettings', 'Importing lorebook settings...', () => lorebookImporter.importLorebookSettings(kv, ls));
    await step('importChats', 'Importing chats...', () => chatImporter.importChats(kv));
    await step('importPresets', 'Importing presets...', () => presetImporter.importPresets(kv, ls));
    await step('importJsActiveSelections', 'Importing settings...', () => _importJsActiveSelections(kv, ls));
    await step('importGalleryFromCharacters', 'Importing gallery...', () => characterImporter.importGalleryFromCharacters(data['characters']));
    await step('importDeletedEntries', 'Importing deleted entries...', () => presetImporter.importDeletedEntries(ls, kv));
    await step('importTheme', 'Importing theme...', () => presetImporter.importTheme(ls, kv));
    await _resetSeededFlags();
    onProgress?.call('Finalizing...');
  }

  Future<void> _clearAllTables() async {
    await db.customStatement('PRAGMA foreign_keys = OFF');
    await db.transaction(() async {
      const tables = [
        'characters',
        'chat_sessions',
        'presets',
        'api_configs',
        'personas',
        'lorebooks',
        'embeddings',
        'chat_summaries',
        'memory_book_rows',
        'extension_presets',
        'info_blocks',
      ];
      for (final table in tables) {
        try {
          await db.customStatement('DELETE FROM $table');
        } catch (_) {}
      }
    });
    await db.customStatement('PRAGMA foreign_keys = ON');
  }

  Future<void> _importJsActiveSelections(
      Map<String, dynamic> kv, Map<String, dynamic> ls) async {
    final prefs = await SharedPreferences.getInstance();

    final activePresetId =
        ls['silly_cradle_current_preset_id'] ?? kv['gz_active_preset'];
    if (activePresetId is String && activePresetId.isNotEmpty) {
      await prefs.setString('activePresetId', activePresetId);
    }

    final activePersonaRaw = ls['gz_active_persona'] ?? kv['gz_active_persona'];
    if (activePersonaRaw is String) {
      try {
        final persona = jsonDecode(activePersonaRaw) as Map<String, dynamic>;
        final id = persona['id'] as String?;
        if (id != null) await prefs.setString('activePersonaId', id);
      } catch (_) {}
    } else if (activePersonaRaw is Map) {
      final id = activePersonaRaw['id'] as String?;
      if (id != null) await prefs.setString('activePersonaId', id);
    }

    final presetConnections =
        ls['gz_preset_connections'] ?? kv['gz_preset_connections'];
    if (presetConnections is String) {
      try {
        await prefs.setString('presetConnections', presetConnections);
      } catch (_) {}
    } else if (presetConnections is Map) {
      await prefs.setString(
          'presetConnections', jsonEncode(presetConnections));
    }

    final personaConnections =
        ls['gz_persona_connections'] ?? kv['gz_persona_connections'];
    if (personaConnections is String) {
      try {
        await prefs.setString('personaConnections', personaConnections);
      } catch (_) {}
    } else if (personaConnections is Map) {
      await prefs.setString(
          'personaConnections', jsonEncode(personaConnections));
    }

    for (final entry in ls.entries) {
      if (entry.key.startsWith('gz_imggen_') && entry.value is String) {
        final value = entry.value as String;
        if (value == 'true' || value == 'false') {
          await prefs.setBool(entry.key, value == 'true');
        } else if (int.tryParse(value) != null) {
          await prefs.setInt(entry.key, int.parse(value));
        } else {
          await prefs.setString(entry.key, value);
        }
      }
    }
    await prefs.remove('gz_imggen_settings');

    final regexScriptsRaw = ls['regex_scripts'] ?? kv['regex_scripts'];
    if (regexScriptsRaw is String) {
      try {
        final decoded = jsonDecode(regexScriptsRaw);
        if (decoded is List) {
          final existing = prefs.getString('gz_global_regex_scripts');
          List<dynamic> merged = existing != null ? jsonDecode(existing) as List : [];
          final existingIds = merged.map((e) => (e as Map<String, dynamic>)['id']?.toString()).toSet();
          for (final item in decoded) {
            if (item is Map<String, dynamic> && !existingIds.contains(item['id']?.toString())) {
              final normalized = normalizeJsGlobalRegex(item);
              merged.add(normalized);
              existingIds.add(normalized['id']?.toString());
            }
          }
          await prefs.setString('gz_global_regex_scripts', jsonEncode(merged));
        }
      } catch (_) {}
    } else if (regexScriptsRaw is List) {
      final existing = prefs.getString('gz_global_regex_scripts');
      List<dynamic> merged = existing != null ? jsonDecode(existing) as List : [];
      final existingIds = merged.map((e) => (e as Map<String, dynamic>)['id']?.toString()).toSet();
      for (final item in regexScriptsRaw) {
        if (item is Map<String, dynamic> && !existingIds.contains(item['id']?.toString())) {
          final normalized = normalizeJsGlobalRegex(item);
          merged.add(normalized);
          existingIds.add(normalized['id']?.toString());
        }
      }
      await prefs.setString('gz_global_regex_scripts', jsonEncode(merged));
    }

    final memSettingsRaw =
        ls['gz_memory_settings'] ?? kv['gz_memory_settings'];
    if (memSettingsRaw is String) {
      try {
        await prefs.setString('memorySettings', memSettingsRaw);
      } catch (_) {}
    } else if (memSettingsRaw is Map<String, dynamic>) {
      await prefs.setString('memorySettings', jsonEncode(memSettingsRaw));
    }

    final activeLlmId =
        ls['gz_active_llm_profile_id'] ?? kv['gz_active_llm_profile_id'];
    if (activeLlmId is String && activeLlmId.isNotEmpty) {
      await prefs.setString('activeApiConfigId', activeLlmId);
    }

    final globalVars = ls['gz_global_vars'];
    if (globalVars is String) {
      await prefs.setString('globalVars', globalVars);
    } else if (globalVars is Map<String, dynamic>) {
      await prefs.setString('globalVars', jsonEncode(globalVars));
    }

    for (final entry in ls.entries) {
      if (!entry.key.startsWith('gz_vars_')) continue;
      final parts = entry.key.substring('gz_vars_'.length).split('_');
      if (parts.length < 2) continue;
      final charId = parts[0];
      final sessionIdx = int.tryParse(parts[1]);
      if (sessionIdx == null) continue;
      final sessionId = '${charId}_$sessionIdx';
      final varsJson = entry.value is String
          ? entry.value as String
          : (entry.value is Map ? jsonEncode(entry.value) : null);
      if (varsJson != null) {
        await (db.update(db.chatSessions)
              ..where((t) => t.sessionId.equals(sessionId)))
            .write(ChatSessionsCompanion(sessionVarsJson: Value(varsJson)));
      }
    }
  }

  Future<void> _resetSeededFlags() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('defaultPresetsSeeded');
  }
}
