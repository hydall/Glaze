import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../shared/theme/theme_preset.dart';
import '../../../shared/theme/theme_preset_storage.dart';
import '../../db/app_db.dart';
import '../image_storage_service.dart';
import 'backup_helpers.dart';

class JsPresetImporter extends BackupHelpers {
  @override
  final AppDatabase db;
  @override
  final ImageStorageService imageStorage;

  JsPresetImporter(this.db, this.imageStorage);

  Future<void> importPresets(
      Map<String, dynamic> kv, Map<String, dynamic> ls) async {
    final presetList = <Map<String, dynamic>>[];

    for (final source in [kv, ls]) {
      final sillyCradleRaw = source['silly_cradle_presets'];
      if (sillyCradleRaw == null) continue;

      Map<String, dynamic> presetsMap;
      if (sillyCradleRaw is String) {
        try {
          presetsMap = jsonDecode(sillyCradleRaw) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
      } else if (sillyCradleRaw is Map<String, dynamic>) {
        presetsMap = sillyCradleRaw;
      } else {
        continue;
      }

      var inner = presetsMap['presets'];
      if (inner is Map<String, dynamic>) {
        for (final entry in inner.entries) {
          if (entry.value is Map<String, dynamic>) {
            presetList.add(entry.value as Map<String, dynamic>);
          }
        }
      } else if (inner is List) {
        for (final p in inner) {
          if (p is Map<String, dynamic>) presetList.add(p);
        }
      } else {
        for (final entry in presetsMap.entries) {
          final v = entry.value;
          if (v is Map<String, dynamic> && v.containsKey('name')) {
            presetList.add(v);
          }
        }
      }
    }

    if (presetList.isEmpty) return;

    for (final presetJson in presetList) {
      try {
        final preset = mapJsPreset(presetJson);
        await db.into(db.presets).insertOnConflictUpdate(
              PresetsCompanion.insert(
                presetId: preset.id,
                name: preset.name,
                dataJson: jsonEncode(preset.toJson()),
              ),
            );
      } catch (_) {}
    }
  }

  Future<void> importDeletedEntries(
      Map<String, dynamic> ls, Map<String, dynamic> kv) async {
    final merged = <String, dynamic>{...kv, ...ls};
    final deletedEntries = <Map<String, dynamic>>[];

    for (final entry in merged.entries) {
      if (!entry.key.startsWith('gz_deleted_')) continue;
      final type = entry.key.substring('gz_deleted_'.length);
      if (entry.value is List) {
        for (final id in entry.value as List) {
          deletedEntries.add({'type': type, 'id': id.toString()});
        }
      } else if (entry.value is String) {
        try {
          final decoded = jsonDecode(entry.value as String);
          if (decoded is List) {
            for (final id in decoded) {
              deletedEntries.add({'type': type, 'id': id.toString()});
            }
          }
        } catch (_) {}
      }
    }

    if (deletedEntries.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'gz_sync_deleted_entries', jsonEncode(deletedEntries));
    }
  }

  Future<void> importTheme(Map<String, dynamic> ls, Map<String, dynamic> kv) async {
    final prefs = await SharedPreferences.getInstance();

    final themeState = ls['gz_theme_state'];
    if (themeState is String) {
      try {
        final theme = jsonDecode(themeState) as Map<String, dynamic>;
        final accent = theme['accent'] as String?;
        if (accent != null && accent.isNotEmpty) {
          final clean = accent.replaceFirst('#', '');
          await prefs.setString('theme_accent', clean);
        }
        final isDark = theme['dark'] as bool?;
        if (isDark != null) {
          await prefs.setInt('theme_mode', isDark ? 2 : 0);
        }
        final chatLayout = theme['chatLayout'] as String?;
        if (chatLayout != null && chatLayout.isNotEmpty) {
          await prefs.setString('chatLayout', chatLayout);
        }
      } catch (_) {}
    }

    final presetsRaw = ls['gz_theme_presets'] ?? kv['gz_theme_presets'];
    List<dynamic>? presetsList;
    if (presetsRaw is String) {
      try {
        presetsList = jsonDecode(presetsRaw) as List<dynamic>;
      } catch (_) {}
    } else if (presetsRaw is List) {
      presetsList = presetsRaw;
    }

    if (presetsList == null || presetsList.isEmpty) return;

    final activeId = (ls['gz_theme_active_preset'] ?? kv['gz_theme_active_preset'] ?? 'default').toString();
    final storage = await ThemePresetStorage.create();
    final imported = <ThemePreset>[];

    for (final p in presetsList) {
      if (p is! Map<String, dynamic>) continue;
      try {
        final preset = ThemePreset.fromJson(p);
        imported.add(preset);
      } catch (_) {
        continue;
      }
    }

    if (imported.isNotEmpty) {
      await storage.saveAll(imported);

      final active = imported.firstWhere(
        (p) => p.id == activeId,
        orElse: () => imported.first,
      );
      await storage.setActive(active.id);

      final accent = active.accentColor;
      if (accent.isNotEmpty) {
        final clean = accent.replaceFirst('#', '');
        await prefs.setString('theme_accent', clean);
      }
    }
  }
}
