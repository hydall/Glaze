import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/embedding_types.dart';
import '../../../core/llm/lorebook_coverage.dart';
import '../../../core/models/lorebook.dart';
import '../../../core/state/character_provider.dart';
import '../../../core/state/lorebook_embedding_provider.dart';
import '../../../core/state/lorebook_provider.dart';
import '../chat_provider.dart';

/// Lorebook coverage for one character's open session.
///
/// Lives here rather than inside the coverage sheet because two surfaces read
/// it now — the Prompt Inspector's coverage tab and the context card under the
/// chat header — and running the scan (plus a vector query) twice for the same
/// turn would be both slow and, with vectors in play, two different answers.
///
/// It recomputes when the message count, the books or the lorebook settings
/// change; a mid-stream token does not move any of those, so a generation costs
/// one recompute at the end, not one per chunk. `ref.invalidate` drives the
/// manual refresh buttons.
///
/// With a hybrid/vector search type and an embedding endpoint configured, that
/// recompute includes one embedding query per turn — the price of the preview
/// agreeing with the prompt. Switching the context card off in the interface
/// settings drops the subscription (and the query) entirely.
final lorebookCoverageProvider = FutureProvider.autoDispose
    .family<CoverageResult, String>((ref, charId) async {
      // Narrow watches: the scan depends on which messages exist, not on the
      // text streaming into the last one.
      ref.watch(
        chatProvider(charId).select((s) => s.value?.messages.length ?? 0),
      );
      ref.watch(chatProvider(charId).select((s) => s.value?.session?.id));
      final lorebooks =
          ref.watch(lorebooksProvider).value ?? const <Lorebook>[];
      final settings = ref.watch(lorebookSettingsProvider);
      final activations = ref.watch(lorebookActivationsProvider);

      final session = ref.read(chatProvider(charId)).value?.session;
      if (session == null) return CoverageResult.empty;

      final character = ref.read(characterByIdProvider(charId));

      final nonHidden = session.messages.where((m) => !m.isHidden).toList();
      var lastUserMsg = '';
      for (final m in nonHidden.reversed) {
        if (m.role == 'user') {
          lastUserMsg = m.content;
          break;
        }
      }

      // Run vector search so vector-matched entries appear in coverage.
      var vectorEntries = const <LorebookEntry>[];
      var vectorEntryLorebookIds = const <String, String>{};
      if (settings.searchType != 'keyword') {
        final embeddingConfig = ref.read(embeddingConfigProvider);
        if (embeddingConfig.endpoint.isNotEmpty) {
          try {
            final searchService = ref.read(lorebookVectorSearchProvider);
            final searchHistory = session.messages
                .map(
                  (m) => ChatMessageForSearch(role: m.role, content: m.content),
                )
                .toList();
            final results = await searchService.search(
              searchHistory,
              lastUserMsg,
              lorebooks,
              settings,
              embeddingConfig,
              charWorld: character?.world,
              character: character,
              activations: activations,
              chatId: session.id,
            );
            final entryMap = <String, LorebookEntry>{};
            final entryToLbId = <String, String>{};
            for (final lb in lorebooks) {
              for (final entry in lb.entries) {
                entryMap['${lb.id}_${entry.id}'] = entry;
              }
            }
            vectorEntries = results
                .where(
                  (r) => entryMap.containsKey('${r.lorebookId}_${r.entryId}'),
                )
                .map((r) {
                  final key = '${r.lorebookId}_${r.entryId}';
                  entryToLbId[key] = r.lorebookId;
                  final lorebook = lorebooks
                      .where((book) => book.id == r.lorebookId)
                      .firstOrNull;
                  return entryMap[key]!.copyWith(
                    lorebookId: r.lorebookId,
                    lorebookName: lorebook?.name ?? '',
                  );
                })
                .toList();
            vectorEntryLorebookIds = entryToLbId;
          } catch (e, st) {
            debugPrint('COVERAGE: vector search error: $e\n$st');
          }
        }
      }

      // Off the current frame: the keyword scan is synchronous and can walk a
      // few thousand entries.
      return Future(
        () => computeLorebookCoverage(
          history: session.messages,
          char: character,
          textToScan: lastUserMsg,
          chatId: session.id,
          lorebooks: lorebooks,
          globalSettings: settings,
          activations: activations,
          vectorEntries: vectorEntries,
          vectorEntryLorebookIds: vectorEntryLorebookIds,
        ),
      );
    });
