import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../features/chat/chat_provider.dart';
import '../../features/presets/preset_list_provider.dart';
import '../llm/summary_service.dart';
import '../models/preset.dart';
import '../services/memory_prompt_presets.dart' show MemoryPromptPreset;
import 'db_provider.dart';
import 'shared_prefs_provider.dart';

final summaryServiceProvider = Provider<SummaryService>((ref) {
  return SummaryService(ref.watch(summaryRepoProvider));
});

/// How many new messages must accumulate before the summary is regenerated on
/// its own. `0` disables auto-generation. Global, not per chat.
final summaryAutoIntervalProvider =
    AsyncNotifierProvider<SummaryAutoIntervalNotifier, int>(
      SummaryAutoIntervalNotifier.new,
    );

class SummaryAutoIntervalNotifier extends AsyncNotifier<int> {
  static const prefsKey = 'summaryAutoInterval';

  @override
  Future<int> build() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final value = prefs.get(prefsKey);
    if (value is int) return value < 0 ? 0 : value;
    if (value is String) return int.tryParse(value)?.clamp(0, 9999) ?? 0;
    return 0;
  }

  Future<void> set(int interval) async {
    final normalized = interval < 0 ? 0 : interval;
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setInt(prefsKey, normalized);
    state = AsyncData(normalized);
  }
}

/// Summarization prompts the reader has written and saved, shared across every
/// chat — the same thing Memory Books keeps its custom drafting prompts for.
/// Global rather than per session: a prompt worth writing is worth reusing.
final summaryCustomPromptsProvider =
    AsyncNotifierProvider<
      SummaryCustomPromptsNotifier,
      List<MemoryPromptPreset>
    >(SummaryCustomPromptsNotifier.new);

class SummaryCustomPromptsNotifier
    extends AsyncNotifier<List<MemoryPromptPreset>> {
  static const prefsKey = 'summaryCustomPrompts';

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
      debugPrint('[summaryCustomPrompts] unreadable, ignoring: $e');
      return const [];
    }
  }
}

/// Bumped whenever a session's summary is written (manual edit or generation).
/// UI that reads summary content off the repo watches this to refetch, since
/// the repo write does not flow through `chatProvider`.
final summaryRevisionProvider = StateProvider<int>((ref) => 0);

/// Reactive summary content for a session. Refetches when
/// [summaryRevisionProvider] is bumped.
final summaryContentProvider = FutureProvider.autoDispose
    .family<String?, String>((ref, sessionId) {
      ref.watch(summaryRevisionProvider);
      return ref.watch(summaryServiceProvider).getSummary(sessionId);
    });

final summaryEnabledProvider = FutureProvider.autoDispose.family<bool, String>((
  ref,
  sessionId,
) {
  ref.watch(summaryRevisionProvider);
  return ref.watch(summaryServiceProvider).isSummaryEnabled(sessionId);
});

Future<void> syncSummaryEnabled(
  WidgetRef ref, {
  required String? charId,
  required bool enabled,
}) async {
  if (charId != null) {
    final session = ref.read(chatProvider(charId)).value?.session;
    if (session != null) {
      await ref
          .read(summaryServiceProvider)
          .setSummaryEnabled(sessionId: session.id, enabled: enabled);
      ref.read(summaryRevisionProvider.notifier).state++;
    }
  }

  final presets = ref.read(presetListProvider).value ?? const [];
  for (final preset in presets) {
    final idx = preset.blocks.indexWhere((b) => b.id == 'summary');
    if (idx == -1 || preset.blocks[idx].enabled == enabled) continue;
    final blocks = List<PresetBlock>.from(preset.blocks)
      ..[idx] = preset.blocks[idx].copyWith(enabled: enabled);
    await ref
        .read(presetListProvider.notifier)
        .updatePreset(preset.copyWith(blocks: blocks));
  }
}
