import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/memory_prompt_presets.dart' show MemoryPromptPreset;
import 'shared_prefs_provider.dart';

/// Translation prompts the reader has written and saved, shared across every
/// chat — the same thing Memory Books and Summary keep their custom prompts
/// for. Global rather than per session: a prompt worth writing is worth reusing.
final translationCustomPromptsProvider =
    AsyncNotifierProvider<
      TranslationCustomPromptsNotifier,
      List<MemoryPromptPreset>
    >(TranslationCustomPromptsNotifier.new);

class TranslationCustomPromptsNotifier
    extends AsyncNotifier<List<MemoryPromptPreset>> {
  static const prefsKey = 'translationCustomPrompts';

  @override
  Future<List<MemoryPromptPreset>> build() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    return _decode(prefs.getString(prefsKey));
  }

  Future<void> save(List<MemoryPromptPreset> prompts) async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setString(
      prefsKey,
      jsonEncode(MemoryPromptPreset.toJsonList(prompts)),
    );
    state = AsyncData(List.unmodifiable(prompts));
  }

  /// A stored list that cannot be read is not worth crashing the settings
  /// sheet over — the reader can write new prompts, and the unreadable string
  /// is left alone rather than overwritten.
  static List<MemoryPromptPreset> _decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final entry in decoded)
          if (entry is Map<String, dynamic>) MemoryPromptPreset.fromJson(entry),
      ];
    } catch (e) {
      debugPrint('[translationCustomPrompts] unreadable, ignoring: $e');
      return const [];
    }
  }
}
