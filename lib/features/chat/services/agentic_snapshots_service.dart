import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/repositories/tracker_snapshot_repo.dart';
import '../../../core/db/repositories/chat_repo.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/tracker_snapshot.dart';
import '../../../core/state/db_provider.dart';

final agenticSnapshotsServiceProvider = Provider<AgenticSnapshotsService>((
  ref,
) {
  return AgenticSnapshotsService(
    ref.watch(trackerSnapshotRepoProvider),
    ref.watch(chatRepoProvider),
  );
});

final class AgenticSnapshotView {
  const AgenticSnapshotView({
    required this.snapshot,
    this.startMessageNumber,
    this.endMessageNumber,
  });

  final TrackerSnapshot snapshot;
  final int? startMessageNumber;
  final int? endMessageNumber;
}

class AgenticSnapshotsService {
  const AgenticSnapshotsService(this._snapshotRepo, this._chatRepo);

  final TrackerSnapshotRepo _snapshotRepo;
  final ChatRepo _chatRepo;

  Future<List<AgenticSnapshotView>> loadSnapshots(String sessionId) async {
    final snapshotsFuture = _snapshotRepo.getBySessionId(sessionId);
    final sessionFuture = _chatRepo.getById(sessionId);
    final snapshots = await snapshotsFuture;
    final session = await sessionFuture;
    final messages = session?.messages ?? const [];
    final positions = <String, int>{
      for (var i = 0; i < messages.length; i++) messages[i].id: i,
    };
    return [
      for (final snapshot in snapshots) _toView(snapshot, messages, positions),
    ];
  }

  AgenticSnapshotView _toView(
    TrackerSnapshot snapshot,
    List<ChatMessage> messages,
    Map<String, int> positions,
  ) {
    final index = positions[snapshot.messageId];
    if (index == null) return AgenticSnapshotView(snapshot: snapshot);
    final end = index + 1;
    var start = end;
    if (index >= 1 && messages[index - 1].role == 'user') {
      start = index;
      if (index == 2 && messages.first.role == 'assistant') start = 1;
    }
    return AgenticSnapshotView(
      snapshot: snapshot,
      startMessageNumber: start,
      endMessageNumber: end,
    );
  }
}
