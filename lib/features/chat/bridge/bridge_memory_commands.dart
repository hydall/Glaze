import 'chat_bridge_controller.dart';

/// Outgoing memory-book commands + state tracker. The WebView reads
/// covered/pending/draft memory IDs from the host to badge messages
/// with the right memory state chip.
class MemoryBridgeCommands {
  final ChatBridgeController _host;
  Future<void>? _patchPending;

  MemoryBridgeCommands(this._host);

  Future<void> updateMemoryBookData({
    required List<Map<String, dynamic>> entries,
    required List<Map<String, dynamic>> pendingDrafts,
    bool patchMessages = true,
  }) async {
    final previousStatuses = <String, String?>{
      for (final id in _host.coveredMemoryIds) id: 'MEM',
      for (final id in _host.pendingMemoryIds) id: 'PENDING',
      for (final id in _host.draftMemoryIds) id: 'DRAFT',
    };
    _host.coveredMemoryIds.clear();
    _host.pendingMemoryIds.clear();
    _host.draftMemoryIds.clear();
    for (final entry in entries) {
      final status = entry['status'] as String?;
      final ids = entry['messageIds'];
      if (ids is List) {
        if (status == 'active') {
          for (final id in ids) {
            _host.coveredMemoryIds.add(id.toString());
          }
        } else if (status == 'pending_generation') {
          for (final id in ids) {
            _host.pendingMemoryIds.add(id.toString());
          }
        }
      }
    }
    for (final draft in pendingDrafts) {
      final ids = draft['messageIds'];
      if (ids is List) {
        for (final id in ids) {
          _host.draftMemoryIds.add(id.toString());
        }
      }
    }

    if (!patchMessages) return;

    final changedIds = <String>{
      ...previousStatuses.keys,
      ..._host.coveredMemoryIds,
      ..._host.pendingMemoryIds,
      ..._host.draftMemoryIds,
    };
    if (changedIds.isEmpty) return;

    final statuses = <String, String?>{};
    for (final id in changedIds) {
      final status = _host.coveredMemoryIds.contains(id)
          ? 'MEM'
          : _host.pendingMemoryIds.contains(id)
          ? 'PENDING'
          : _host.draftMemoryIds.contains(id)
          ? 'DRAFT'
          : null;
      if (previousStatuses[id] != status) statuses[id] = status;
    }
    if (statuses.isEmpty) return;
    final previous = _patchPending;
    late final Future<void> operation;
    operation = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          // A failed/stale WebView call must not poison later status patches.
        }
      }
      await _host.patchMemoryStatuses(statuses);
    }();
    _patchPending = operation;
    try {
      await operation;
    } finally {
      if (identical(_patchPending, operation)) _patchPending = null;
    }
  }
}
