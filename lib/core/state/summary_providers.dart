import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../features/chat/chat_provider.dart';
import '../../features/presets/preset_list_provider.dart';
import '../llm/summary_service.dart';
import '../models/preset.dart';
import '../services/memory_prompt_presets.dart' show MemoryPromptPreset;
import '../services/summary_prompt_presets.dart';
import 'db_provider.dart';
import 'shared_prefs_provider.dart';

final summaryServiceProvider = Provider<SummaryService>((ref) {
  return SummaryService(ref.watch(summaryRepoProvider));
});

/// When and how big the summary compacts. Global, not per chat.
class SummaryCompactionSettings {
  /// Compact on its own after a bot reply once the prompt is full enough.
  final bool autoEnabled;

  /// How full the context may get, in percent of what the prompt may use,
  /// before old messages are summarized. The rest is the fresh tail that is
  /// always sent as is.
  final int triggerPercent;

  /// Ceiling for one block. A small run of messages gets a smaller target.
  final int blockTargetTokens;

  /// Once the live blocks take more than this share of the context, adjacent
  /// blocks are merged a level up.
  final int mergePercent;

  const SummaryCompactionSettings({
    this.autoEnabled = false,
    this.triggerPercent = 75,
    this.blockTargetTokens = 1000,
    this.mergePercent = 20,
  });

  static const minTriggerPercent = 50;
  static const maxTriggerPercent = 95;
  static const minBlockTargetTokens = 200;
  static const maxBlockTargetTokens = 4000;
  static const minMergePercent = 5;
  static const maxMergePercent = 50;

  SummaryCompactionSettings copyWith({
    bool? autoEnabled,
    int? triggerPercent,
    int? blockTargetTokens,
    int? mergePercent,
  }) => SummaryCompactionSettings(
    autoEnabled: autoEnabled ?? this.autoEnabled,
    triggerPercent: triggerPercent ?? this.triggerPercent,
    blockTargetTokens: blockTargetTokens ?? this.blockTargetTokens,
    mergePercent: mergePercent ?? this.mergePercent,
  );

  Map<String, dynamic> toJson() => {
    'autoEnabled': autoEnabled,
    'triggerPercent': triggerPercent,
    'blockTargetTokens': blockTargetTokens,
    'mergePercent': mergePercent,
  };

  factory SummaryCompactionSettings.fromJson(Map<String, dynamic> json) {
    const d = SummaryCompactionSettings();
    int read(String key, int fallback, int min, int max) {
      final value = json[key];
      return value is num ? value.toInt().clamp(min, max) : fallback;
    }

    return SummaryCompactionSettings(
      autoEnabled: json['autoEnabled'] == true,
      triggerPercent: read(
        'triggerPercent',
        d.triggerPercent,
        minTriggerPercent,
        maxTriggerPercent,
      ),
      blockTargetTokens: read(
        'blockTargetTokens',
        d.blockTargetTokens,
        minBlockTargetTokens,
        maxBlockTargetTokens,
      ),
      mergePercent: read(
        'mergePercent',
        d.mergePercent,
        minMergePercent,
        maxMergePercent,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SummaryCompactionSettings &&
      other.autoEnabled == autoEnabled &&
      other.triggerPercent == triggerPercent &&
      other.blockTargetTokens == blockTargetTokens &&
      other.mergePercent == mergePercent;

  @override
  int get hashCode =>
      Object.hash(autoEnabled, triggerPercent, blockTargetTokens, mergePercent);
}

final summaryCompactionSettingsProvider =
    AsyncNotifierProvider<
      SummaryCompactionSettingsNotifier,
      SummaryCompactionSettings
    >(SummaryCompactionSettingsNotifier.new);

class SummaryCompactionSettingsNotifier
    extends AsyncNotifier<SummaryCompactionSettings> {
  static const prefsKey = 'summaryCompaction';

  /// The "every N messages" setting it replaces. Read once so a reader who
  /// had auto-summary on keeps it on.
  static const legacyIntervalKey = 'summaryAutoInterval';

  @override
  Future<SummaryCompactionSettings> build() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final raw = prefs.getString(prefsKey);
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          return SummaryCompactionSettings.fromJson(decoded);
        }
      } catch (e) {
        debugPrint('[summaryCompaction] unreadable, using defaults: $e');
      }
      return const SummaryCompactionSettings();
    }
    final legacy = prefs.get(legacyIntervalKey);
    final legacyOn =
        (legacy is int && legacy > 0) ||
        (legacy is String && (int.tryParse(legacy) ?? 0) > 0);
    return SummaryCompactionSettings(autoEnabled: legacyOn);
  }

  Future<void> save(SummaryCompactionSettings settings) async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setString(prefsKey, jsonEncode(settings.toJson()));
    await prefs.remove(legacyIntervalKey);
    state = AsyncData(settings);
  }
}

/// Which saved or built-in prompt summarizing runs on. Global, like the
/// compaction settings. Keys are resolved by [SummaryPromptPresets] and
/// [SummaryMergePromptPresets]; a key that names nothing falls back to the
/// built-in default.
///
/// A chat that still holds a prompt text of its own (from before presets were
/// chosen by key) retells with that text until a preset is picked for it.
class SummaryPromptSelection {
  final String retellKey;
  final String mergeKey;

  const SummaryPromptSelection({
    this.retellKey = SummaryPromptPresets.fallbackKey,
    this.mergeKey = SummaryMergePromptPresets.fallbackKey,
  });

  SummaryPromptSelection copyWith({String? retellKey, String? mergeKey}) =>
      SummaryPromptSelection(
        retellKey: retellKey ?? this.retellKey,
        mergeKey: mergeKey ?? this.mergeKey,
      );

  Map<String, dynamic> toJson() => {'retell': retellKey, 'merge': mergeKey};

  factory SummaryPromptSelection.fromJson(Map<String, dynamic> json) {
    const d = SummaryPromptSelection();
    String read(String key, String fallback) {
      final value = json[key];
      return value is String && value.isNotEmpty ? value : fallback;
    }

    return SummaryPromptSelection(
      retellKey: read('retell', d.retellKey),
      mergeKey: read('merge', d.mergeKey),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SummaryPromptSelection &&
      other.retellKey == retellKey &&
      other.mergeKey == mergeKey;

  @override
  int get hashCode => Object.hash(retellKey, mergeKey);
}

final summaryPromptSelectionProvider =
    AsyncNotifierProvider<
      SummaryPromptSelectionNotifier,
      SummaryPromptSelection
    >(SummaryPromptSelectionNotifier.new);

class SummaryPromptSelectionNotifier
    extends AsyncNotifier<SummaryPromptSelection> {
  static const prefsKey = 'summaryPromptSelection';

  @override
  Future<SummaryPromptSelection> build() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final raw = prefs.getString(prefsKey);
    if (raw == null || raw.trim().isEmpty) {
      return const SummaryPromptSelection();
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return SummaryPromptSelection.fromJson(decoded);
      }
    } catch (e) {
      debugPrint('[summaryPromptSelection] unreadable, using defaults: $e');
    }
    return const SummaryPromptSelection();
  }

  Future<void> save(SummaryPromptSelection selection) async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setString(prefsKey, jsonEncode(selection.toJson()));
    state = AsyncData(selection);
  }
}

/// Retelling prompts the reader has written and saved, shared across every
/// chat — the same thing Memory Books keeps its custom drafting prompts for.
final summaryCustomPromptsProvider =
    AsyncNotifierProvider<
      SummaryCustomPromptsNotifier,
      List<MemoryPromptPreset>
    >(SummaryCustomPromptsNotifier.new);

class SummaryCustomPromptsNotifier extends _PromptLibraryNotifier {
  static const prefsKey = 'summaryCustomPrompts';

  @override
  String get _prefsKey => prefsKey;
}

/// Merge prompts the reader has written and saved.
final summaryCustomMergePromptsProvider =
    AsyncNotifierProvider<
      SummaryCustomMergePromptsNotifier,
      List<MemoryPromptPreset>
    >(SummaryCustomMergePromptsNotifier.new);

class SummaryCustomMergePromptsNotifier extends _PromptLibraryNotifier {
  static const prefsKey = 'summaryCustomMergePrompts';

  @override
  String get _prefsKey => prefsKey;
}

abstract class _PromptLibraryNotifier
    extends AsyncNotifier<List<MemoryPromptPreset>> {
  String get _prefsKey;

  @override
  Future<List<MemoryPromptPreset>> build() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    return _decode(prefs.getString(_prefsKey));
  }

  Future<void> save(List<MemoryPromptPreset> prompts) async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setString(
      _prefsKey,
      jsonEncode(MemoryPromptPreset.toJsonList(prompts)),
    );
    state = AsyncData(List.unmodifiable(prompts));
  }

  /// A stored list that cannot be read is not worth crashing the settings
  /// sheet over — the reader can write new prompts, and the unreadable string
  /// is left alone rather than overwritten.
  List<MemoryPromptPreset> _decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final entry in decoded)
          if (entry is Map<String, dynamic>) MemoryPromptPreset.fromJson(entry),
      ];
    } catch (e) {
      debugPrint('[$_prefsKey] unreadable, ignoring: $e');
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
