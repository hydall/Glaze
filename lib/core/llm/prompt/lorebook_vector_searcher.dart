import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/lorebook_embedding_provider.dart';
import '../../state/lorebook_provider.dart';
import '../../db/repositories/session_lorebook_evolution_repo.dart';
import '../embedding_types.dart';
import '../lorebook_vector_search.dart';
import '../../models/character.dart';
import '../../models/chat_message.dart';
import '../../models/lorebook.dart';

class LorebookVectorSearchDiagnostic {
  final Object error;
  final StackTrace stackTrace;

  const LorebookVectorSearchDiagnostic({
    required this.error,
    required this.stackTrace,
  });
}

/// Performs lorebook vector (embedding) search for prompt payload building.
///
/// Wraps [LorebookVectorSearch] with provider-based config reads, activation
/// filtering, and graceful error handling. Returns an empty list when vector
/// search is disabled (keyword mode), no embedding endpoint is configured, or
/// the search fails.
class LorebookVectorSearcher {
  final Ref _ref;
  final void Function(LorebookVectorSearchDiagnostic diagnostic)? onDiagnostic;

  LorebookVectorSearcher(this._ref, {this.onDiagnostic});

  Future<List<LorebookEntry>> search(
    List<ChatMessage> history,
    String currentText,
    String? charWorld,
    Character? character, {
    required List<Lorebook> lorebooks,
    Set<SessionLorebookTarget> sessionOverlayTargets = const {},
    String? chatId,
    CancelToken? cancelToken,
  }) async {
    final settings = _ref.read(lorebookSettingsProvider);
    if (settings.searchType == 'keyword') return [];

    final config = _ref.read(embeddingConfigProvider);
    if (config.endpoint.isEmpty) return [];

    if (lorebooks.isEmpty) return [];

    try {
      final searchService = _ref.read(lorebookVectorSearchProvider);
      final visibleHistory = history
          .where((m) => !m.isHidden && !m.isTyping)
          .toList();
      final searchHistory = visibleHistory
          .map((m) => ChatMessageForSearch(role: m.role, content: m.content))
          .toList();
      final activations = _ref.read(lorebookActivationsProvider);
      // Let the vector search use its own vectorTopK setting (with per-book
      // overrides).  Previously this passed maxInjectedEntries as overrideTopK,
      // which made vectorTopK a dead setting in hybrid mode.  The merger now
      // caps vector entries at min(vectorTopK, remainingSlots) regardless of
      // how many candidates the search returns.
      final results = await searchService.search(
        searchHistory,
        currentText,
        lorebooks,
        settings,
        config,
        charWorld: charWorld,
        character: character,
        activations: activations,
        chatId: chatId,
        sessionOverlayTargets: sessionOverlayTargets,
        cancelToken: cancelToken,
      );

      // Key by "lorebookId_entryId" to avoid collisions between lorebooks
      // whose entries share the same numeric id.
      final entryMap = <String, LorebookEntry>{};
      final lorebookNames = <String, String>{};
      for (final lb in lorebooks) {
        lorebookNames[lb.id] = lb.name;
        for (final entry in lb.entries) {
          entryMap['${lb.id}_${entry.id}'] = entry;
        }
      }
      return results
          .where((r) => entryMap.containsKey('${r.lorebookId}_${r.entryId}'))
          .map(
            (r) => entryMap['${r.lorebookId}_${r.entryId}']!.copyWith(
              lorebookId: r.lorebookId,
              lorebookName: lorebookNames[r.lorebookId] ?? '',
            ),
          )
          .toList();
    } catch (e, st) {
      if (cancelToken?.isCancelled == true ||
          (e is DioException && CancelToken.isCancel(e))) {
        return [];
      }
      debugPrint('VECTOR SEARCH: failed: $e\n$st');
      onDiagnostic?.call(
        LorebookVectorSearchDiagnostic(error: e, stackTrace: st),
      );
      return [];
    }
  }
}
