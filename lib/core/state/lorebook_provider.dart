import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/lorebook.dart';
import 'db_provider.dart';
import 'shared_prefs_provider.dart';

final lorebooksProvider =
    AsyncNotifierProvider<LorebooksNotifier, List<Lorebook>>(
      LorebooksNotifier.new,
    );

final lorebookSettingsProvider = StateProvider<LorebookGlobalSettings>((ref) {
  return const LorebookGlobalSettings();
});

final lorebookActivationsProvider = StateProvider<LorebookActivations>((ref) {
  return const LorebookActivations();
});

Future<void> loadLorebookActivations(WidgetRef ref) async {
  final prefs = await ref.read(sharedPreferencesProvider.future);
  final raw = prefs.getString('lorebookActivations');
  if (raw != null) {
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final charMap = <String, List<String>>{};
      final chatMap = <String, List<String>>{};

      final char = decoded['character'] as Map<String, dynamic>?;
      if (char != null) {
        for (final e in char.entries) {
          if (e.value is List) {
            charMap[e.key] = (e.value as List)
                .map((v) => v.toString())
                .toList();
          }
        }
      }

      final chat = decoded['chat'] as Map<String, dynamic>?;
      if (chat != null) {
        for (final e in chat.entries) {
          if (e.value is List) {
            chatMap[e.key] = (e.value as List)
                .map((v) => v.toString())
                .toList();
          }
        }
      }

      ref.read(lorebookActivationsProvider.notifier).state =
          LorebookActivations(character: charMap, chat: chatMap);
    } catch (_) {}
  }
}

Future<void> saveLorebookActivations(
  LorebookActivations activations, [
  SharedPreferences? prefs,
]) async {
  prefs ??= await SharedPreferences.getInstance();
  await prefs.setString(
    'lorebookActivations',
    jsonEncode(activations.toJson()),
  );
}

Future<void> loadLorebookSettings(WidgetRef ref) async {
  final prefs = await ref.read(sharedPreferencesProvider.future);
  final settingsJson = prefs.getString('lorebookSettings');
  if (settingsJson != null) {
    try {
      final settings = LorebookGlobalSettings.fromJson(
        jsonDecode(settingsJson) as Map<String, dynamic>,
      );
      ref.read(lorebookSettingsProvider.notifier).state = settings;
    } catch (_) {}
  }
}

Future<void> saveLorebookSettings(
  LorebookGlobalSettings settings, [
  SharedPreferences? prefs,
]) async {
  prefs ??= await SharedPreferences.getInstance();
  await prefs.setString('lorebookSettings', jsonEncode(settings.toJson()));
}

class LorebooksNotifier extends AsyncNotifier<List<Lorebook>> {
  @override
  Future<List<Lorebook>> build() async {
    final repo = ref.read(lorebookRepoProvider);
    return repo.getAll();
  }

  Future<void> addLorebook(Lorebook lorebook) async {
    final repo = ref.read(lorebookRepoProvider);
    await repo.put(lorebook);
    await _syncActivationToPrefs(lorebook);
    ref.invalidateSelf();
  }

  Future<void> put(Lorebook lorebook) async {
    final repo = ref.read(lorebookRepoProvider);
    await repo.put(lorebook);
    debugPrint(
      '[lorebook_provider] put id=${lorebook.id} name=${lorebook.name} '
      'entries=${lorebook.entries.length} scope=${lorebook.activationScope} '
      'target=${lorebook.activationTargetId}',
    );
    await _syncActivationToPrefs(lorebook);
    ref.invalidateSelf();
  }

  Future<void> updateLorebook(Lorebook lorebook) async {
    final repo = ref.read(lorebookRepoProvider);
    await repo.put(lorebook);
    await _syncActivationToPrefs(lorebook);
    ref.invalidateSelf();
  }

  Future<void> _syncActivationToPrefs(Lorebook lorebook) async {
    if (lorebook.activationTargetId == null) return;
    if (lorebook.activationScope != 'character' &&
        lorebook.activationScope != 'chat') {
      return;
    }
    final scope = lorebook.activationScope;
    final targetId = lorebook.activationTargetId!;

    final current = ref.read(lorebookActivationsProvider);
    final map = scope == 'character'
        ? Map<String, List<String>>.from(current.character)
        : Map<String, List<String>>.from(current.chat);
    final list = List<String>.from(map[targetId] ?? []);
    if (!list.contains(lorebook.id)) {
      list.add(lorebook.id);
      map[targetId] = list;
      final updated = scope == 'character'
          ? current.copyWith(character: map)
          : current.copyWith(chat: map);
      ref.read(lorebookActivationsProvider.notifier).state = updated;
      final prefs = ref.read(sharedPreferencesProvider).value;
      await saveLorebookActivations(updated, prefs);
      debugPrint(
        '[lorebook_provider] activation_synced lorebook=${lorebook.id} '
        'scope=$scope target=$targetId ids=${map[targetId]}',
      );
    }
  }

  Future<void> deleteLorebook(String id) async {
    final repo = ref.read(lorebookRepoProvider);
    await repo.delete(id);
    await ref.read(embeddingRepoProvider).deleteBySourceId(id);
    // Note: SyncDeletionTracker is intentionally NOT called for lorebooks.
    // Lorebooks are a singleton type: the entire collection is diffed by hash
    // on push. A per-ID tombstone with key 'lorebooks:<id>' would never match
    // the real manifest entry 'lorebooks:lorebooks' and is therefore dead code.

    final activations = ref.read(lorebookActivationsProvider);
    final charMap = <String, List<String>>{};
    for (final e in activations.character.entries) {
      charMap[e.key] = List<String>.from(e.value);
    }
    final chatMap = <String, List<String>>{};
    for (final e in activations.chat.entries) {
      chatMap[e.key] = List<String>.from(e.value);
    }
    for (final ids in charMap.values) {
      ids.remove(id);
    }
    for (final ids in chatMap.values) {
      ids.remove(id);
    }
    charMap.removeWhere((_, ids) => ids.isEmpty);
    chatMap.removeWhere((_, ids) => ids.isEmpty);
    final cleaned = LorebookActivations(character: charMap, chat: chatMap);
    ref.read(lorebookActivationsProvider.notifier).state = cleaned;
    final prefs = ref.read(sharedPreferencesProvider).value;
    await saveLorebookActivations(cleaned, prefs);

    ref.invalidateSelf();
  }
}
