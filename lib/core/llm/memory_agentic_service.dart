import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/agent_operation_record.dart';
import '../models/memory_book.dart';
import '../models/pipeline_settings.dart';
import 'memory_agentic_tools.dart';
import 'memory_selector.dart';

/// Agentic memory search service.
///
/// This service runs a bounded retrieval loop before generation:
/// 1. Present available memory tools to the LLM via a non-streaming call.
/// 2. The LLM requests `searchMemory` with a query.
/// 3. The app executes bounded retrieval (app-enforced caps, exclusion).
/// 4. Results are injected into the final generation prompt.
///
/// Previously gated by `MemoryBookSettings.memoryMode == 'agentic'`, but the
/// `agentic` mode was removed in Phase 4 of docs/PLAN_AGENTIC_STUDIO.md.
/// Agentic read is now a separate pre-generation tracker concern (wired in
/// Phase 5+); until then this service is effectively disabled.
///
/// Agentic retrieval is currently disabled until it is wired as a bounded
/// pre-generation concern.
class MemoryAgenticService {
  MemoryAgenticService(Ref ref);

  /// Run the agentic memory loop. Returns selected entries + diagnostics.
  Future<MemoryAgenticResult> runAgentic({
    required MemoryBookSettings settings,
    required PipelineSettings pipeline,
    required List<MemoryEntry> entries,
    required String currentText,
    required Set<String> visibleMessageIds,
    required MemorySelection fallbackSelection,
    CancelToken? cancelToken,
  }) async {
    // The `agentic` MemoryBook mode was removed in Phase 4. Agentic read
    // will be wired as a pre-generation memory tracker in a later phase;
    // until then this service is disabled.
    return MemoryAgenticResult(
      status: 'disabled',
      selection: fallbackSelection,
    );
  }
}

class MemoryAgenticResult {
  final String status;
  final MemorySelection selection;
  final String? searchQuery;
  final MemorySearchResult? searchResult;
  final String? error;
  final List<AgentOperationAttempt> attempts;
  final int totalElapsedMs;

  const MemoryAgenticResult({
    required this.status,
    required this.selection,
    this.searchQuery,
    this.searchResult,
    this.error,
    this.attempts = const [],
    this.totalElapsedMs = 0,
  });

  bool get usedModel => status == 'ok' && (searchQuery?.isNotEmpty ?? false);
}
