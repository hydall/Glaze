import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_db.dart';
import '../../../core/db/repositories/llm_request_capture_repo.dart';
import '../../../core/state/db_provider.dart';

final class PromptCaptureView {
  const PromptCaptureView({
    required this.row,
    required this.label,
    required this.request,
    required this.event,
    required this.callEvents,
  });

  final LlmRequestCaptureRow row;
  final String label;
  final Map<String, dynamic> request;
  final Map<String, dynamic> event;
  final List<LlmCallEventRow> callEvents;

  LlmCallEventRow? get transportOutcome {
    for (final item in callEvents) {
      if (item.attempt == row.attempt && item.kind.startsWith('transport_')) {
        return item;
      }
    }
    return null;
  }

  List<LlmCallEventRow> get parserVerdicts => [
    for (final item in callEvents)
      if (item.kind.startsWith('parser_')) item,
  ];

  List<Map<String, dynamic>> get messages {
    final value = request['messages'];
    if (value is! List) return const [];
    return [
      for (final item in value)
        if (item is Map)
          Map<String, dynamic>.unmodifiable(
            item.map((key, value) => MapEntry(key.toString(), value)),
          ),
    ];
  }

  String get formattedJson => const JsonEncoder.withIndent('  ').convert(event);

  static PromptCaptureView? tryParse(
    LlmRequestCaptureRow row, {
    List<LlmCallEventRow> callEvents = const [],
  }) {
    try {
      final decoded = jsonDecode(row.eventJson);
      if (decoded is! Map) return null;
      final event = Map<String, dynamic>.from(decoded);
      return PromptCaptureView(
        row: row,
        label: _stageLabel(row.stage),
        request: event,
        event: event,
        callEvents: List.unmodifiable(callEvents),
      );
    } catch (_) {
      return null;
    }
  }

  static String _stageLabel(String? stage) {
    if (stage == null || stage.isEmpty) return 'Unclassified request';
    const labels = <String, String>{
      'studio.controller': 'Studio controller',
      'studio.post_processing': 'Studio post-processor',
      'studio.final': 'Studio final writer',
      'cleaner.audit': 'Cleaner audit',
      'cleaner.rewrite': 'POST-cleaner',
      'ledger.turn': 'Ledger',
      'ledger.turn_repair': 'Ledger repair',
      'ledger.reconciliation': 'Reconciliation',
      'ledger.reconciliation_repair': 'Reconciliation repair',
      'card.collector': 'Collector',
      'card.history_consolidation': 'History consolidation',
      'card.writer': 'Card writer',
      'card.writer_repair': 'Card writer repair',
      'card.lorebook_writer': 'Lorebook writer',
      'card.manual_writer': 'Manual card writer',
      'summary': 'Summary',
    };
    return labels[stage] ?? stage;
  }
}

final class PromptCaptureViewService {
  const PromptCaptureViewService(this._repo);

  final LlmRequestCaptureRepo _repo;

  Future<List<PromptCaptureView>> load(String sessionId) async {
    final rowsFuture = _repo.newestForSession(sessionId);
    final eventsFuture = _repo.newestCallEventsForSession(sessionId);
    final rows = await rowsFuture;
    final events = await eventsFuture;
    final eventsByCall = <String, List<LlmCallEventRow>>{};
    for (final event in events.reversed) {
      eventsByCall.putIfAbsent(event.callId, () => []).add(event);
    }
    return [
      for (final row in rows)
        ?PromptCaptureView.tryParse(
          row,
          callEvents: row.callId == null
              ? const []
              : eventsByCall[row.callId] ?? const [],
        ),
    ];
  }
}

final promptCaptureViewServiceProvider = Provider<PromptCaptureViewService>(
  (ref) => PromptCaptureViewService(ref.watch(llmRequestCaptureRepoProvider)),
);

final promptCaptureViewsProvider =
    FutureProvider.family<List<PromptCaptureView>, String>(
      (ref, sessionId) =>
          ref.watch(promptCaptureViewServiceProvider).load(sessionId),
    );
