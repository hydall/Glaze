import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../features/chat/chat_provider.dart';
import '../../features/presets/preset_list_provider.dart';
import '../llm/summary_service.dart';
import '../models/preset.dart';
import 'db_provider.dart';

final summaryServiceProvider = Provider<SummaryService>((ref) {
  return SummaryService(ref.watch(summaryRepoProvider));
});

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
