import 'chat_bridge_controller.dart';

/// Outgoing memory-book commands + state tracker. The WebView reads
/// covered/pending/draft memory IDs from the host to badge messages
/// with the right memory state chip.
class MemoryBridgeCommands {
  final ChatBridgeController _host;

  MemoryBridgeCommands(this._host);

  void updateMemoryBookData({
    required List<Map<String, dynamic>> entries,
    required List<Map<String, dynamic>> pendingDrafts,
  }) {
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
  }
}
