import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../db/app_db.dart';
import '../../utils/time_helpers.dart';
import '../image_storage_service.dart';
import 'backup_helpers.dart';

class JsLorebookImporter extends BackupHelpers {
  @override
  final AppDatabase db;
  @override
  final ImageStorageService imageStorage;

  JsLorebookImporter(this.db, this.imageStorage);

  Future<void> importLorebooks(Map<String, dynamic> kv) async {
    final lorebooksRaw = kv['gz_lorebooks'];
    if (lorebooksRaw == null) return;

    List<dynamic>? lorebooks;
    Map<String, dynamic>? globalSettings;
    Map<String, dynamic>? activations;

    if (lorebooksRaw is List) {
      lorebooks = lorebooksRaw;
    } else if (lorebooksRaw is Map<String, dynamic>) {
      final lb = lorebooksRaw;
      final inner = lb['lorebooks'];
      if (inner is List) {
        lorebooks = inner;
      } else {
        lorebooks = lb.values
            .whereType<Map<String, dynamic>>()
            .where((m) => m.containsKey('entries') || m.containsKey('name'))
            .toList();
      }
      if (lb['settings'] is Map<String, dynamic>) {
        globalSettings = lb['settings'] as Map<String, dynamic>;
      }
      if (lb['activations'] is Map<String, dynamic>) {
        activations = lb['activations'] as Map<String, dynamic>;
      }
    }

    if (lorebooks == null) return;

    for (final l in lorebooks) {
      if (l is! Map<String, dynamic>) continue;
      final lbJson = l;
      final rawEntries = lbJson['entries'];
      final mappedEntries = <Map<String, dynamic>>[];

      if (rawEntries is List) {
        for (final e in rawEntries) {
          if (e is Map<String, dynamic>) {
            mappedEntries.add(mapJsLorebookEntry(e));
          }
        }
      } else if (rawEntries is Map) {
        for (final e in rawEntries.values) {
          if (e is Map<String, dynamic>) {
            mappedEntries.add(mapJsLorebookEntry(e));
          }
        }
      }

      final lbSettingsRaw =
          lbJson['settings'] as Map<String, dynamic>? ?? globalSettings;
      final String settingsJsonStr;
      if (lbSettingsRaw != null) {
        final normalized = Map<String, dynamic>.from(lbSettingsRaw);
        final mww = normalized['matchWholeWords'];
        if (mww is bool) {
          normalized['matchWholeWords'] = mww ? 'true' : 'false';
        } else if (mww == null) {
          normalized.remove('matchWholeWords');
        }
        settingsJsonStr = jsonEncode(normalized);
      } else {
        settingsJsonStr = '';
      }

      await db.into(db.lorebooks).insertOnConflictUpdate(
            LorebooksCompanion.insert(
              lorebookId: lbJson['id'] as String? ?? '',
              name: lbJson['name'] as String? ?? '',
              enabled: Value(lbJson['enabled'] as bool? ?? true),
              activationScope: Value(
                  lbJson['activationScope'] as String? ??
                      lbJson['scope'] as String? ??
                      'global'),
              activationTargetId: Value(
                  lbJson['activationTargetId'] as String? ??
                      lbJson['targetId'] as String?),
              entriesJson: jsonEncode(mappedEntries),
              settingsJson: Value(settingsJsonStr),
              description: Value(lbJson['description'] is String
                  ? lbJson['description'] as String
                  : ''),
              updatedAt:
                  Value(toInt(lbJson['updatedAt']) ?? currentTimestampSeconds()),
            ),
          );
    }

    if (activations != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('lorebookActivations', jsonEncode(activations));
    }

    if (globalSettings != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('lorebookSettings', jsonEncode(globalSettings));
    }
  }

  Future<void> importCharacterBooks(dynamic charData) async {
    if (charData is! List) return;
    for (final c in charData) {
      final char = c as Map<String, dynamic>;
      final charId = char['id'] as String?;
      if (charId == null) continue;

      final cbRaw =
          char['character_book'] ?? char['data']?['character_book'];
      if (cbRaw is! Map<String, dynamic>) continue;

      final rawEntries = cbRaw['entries'];
      final mappedEntries = <Map<String, dynamic>>[];

      if (rawEntries is List) {
        for (final e in rawEntries) {
          if (e is Map<String, dynamic>) {
            mappedEntries.add(mapJsLorebookEntry(e));
          }
        }
      } else if (rawEntries is Map) {
        for (final e in rawEntries.values) {
          if (e is Map<String, dynamic>) {
            mappedEntries.add(mapJsLorebookEntry(e));
          }
        }
      }

      if (mappedEntries.isEmpty) continue;

      final cbId = cbRaw['id'] as String? ?? 'cb_$charId';
      final existing = (db.select(db.lorebooks)
            ..where((t) => t.lorebookId.equals(cbId)));
      final existingRow = await existing.getSingleOrNull();
      if (existingRow != null) continue;

      await db.into(db.lorebooks).insertOnConflictUpdate(
            LorebooksCompanion.insert(
              lorebookId: cbId,
              name: cbRaw['name'] as String? ??
                  '${char['name'] ?? 'Char'} Lorebook',
              enabled: Value(cbRaw['enabled'] as bool? ?? false),
              activationScope: Value('character'),
              activationTargetId: Value(charId),
              entriesJson: jsonEncode(mappedEntries),
            ),
          );
    }
  }

  Future<void> importLorebookSettings(
      Map<String, dynamic> kv, Map<String, dynamic> ls) async {
    final prefs = await SharedPreferences.getInstance();
    Map<String, dynamic> settings = {};

    final lorebooksRaw = kv['gz_lorebooks'];
    if (lorebooksRaw is Map<String, dynamic>) {
      final s = lorebooksRaw['settings'];
      if (s is Map<String, dynamic>) {
        settings = Map<String, dynamic>.from(s);
      }
    }

    if (settings.isEmpty) {
      for (final source in [kv, ls]) {
        final raw =
            source['gz_lorebook_settings'] ?? source['lorebook_settings'];
        if (raw == null) continue;
        if (raw is String) {
          try {
            settings = jsonDecode(raw) as Map<String, dynamic>;
          } catch (_) {
            continue;
          }
        } else if (raw is Map<String, dynamic>) {
          settings = raw;
        } else {
          continue;
        }
        break;
      }
    }

    final embThreshold =
        ls['gz_embedding_threshold'] ?? kv['gz_embedding_threshold'];
    final embTopK = ls['gz_embedding_top_k'] ?? kv['gz_embedding_top_k'];
    final embScanDepth =
        ls['gz_embedding_scan_depth'] ?? kv['gz_embedding_scan_depth'];

    if (embThreshold != null && settings['vectorThreshold'] == null) {
      settings['vectorThreshold'] = toDouble(embThreshold) ?? 0.45;
    }
    if (embTopK != null && settings['vectorTopK'] == null) {
      settings['vectorTopK'] = toInt(embTopK) ?? 10;
    }
    if (embScanDepth != null && settings['scanDepth'] == null) {
      settings['scanDepth'] = toInt(embScanDepth) ?? 10;
    }

    if (settings.isNotEmpty) {
      await prefs.setString('lorebookSettings', jsonEncode(settings));
    }
  }
}
