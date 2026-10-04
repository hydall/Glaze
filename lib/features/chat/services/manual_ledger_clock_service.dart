import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/repositories/chat_repo.dart';
import '../../../core/db/repositories/card_evolution_proposal_run_repo.dart';
import '../../../core/db/repositories/ledger_reconciliation_checkpoint_repo.dart';
import '../../../core/db/repositories/ledger_reconciliation_run_repo.dart';
import '../../../core/db/repositories/tracker_repo.dart';
import '../../../core/db/repositories/tracker_snapshot_repo.dart';
import '../../../core/llm/game_time.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/tracker.dart';
import '../../../core/models/tracker_snapshot.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/utils/time_helpers.dart';
import '../chat_session_service.dart';
import 'game_time_message_stamp.dart';

final manualLedgerClockServiceProvider = Provider<ManualLedgerClockService>((
  ref,
) {
  return ManualLedgerClockService(
    chatRepo: ref.watch(chatRepoProvider),
    snapshotRepo: ref.watch(trackerSnapshotRepoProvider),
    trackerRepo: ref.watch(trackerRepoProvider),
    reconciliationRunRepo: ref.watch(ledgerReconciliationRunRepoProvider),
    reconciliationCheckpointRepo: ref.watch(
      ledgerReconciliationCheckpointRepoProvider,
    ),
    proposalRunRepo: ref.watch(cardEvolutionProposalRunRepoProvider),
  );
});

final class ManualLedgerClockEntry {
  const ManualLedgerClockEntry({
    required this.messageNumber,
    required this.messageId,
    required this.swipeId,
    required this.agentSwipeId,
    required this.committed,
    required this.clock,
  });

  final int messageNumber;
  final String messageId;
  final int swipeId;
  final int agentSwipeId;
  final bool committed;
  final GameTimeState clock;
}

final class ManualLedgerClockCorrection {
  const ManualLedgerClockCorrection({required this.entry, required this.clock});

  final ManualLedgerClockEntry entry;
  final GameTimeState clock;
}

class ManualLedgerClockException implements Exception {
  const ManualLedgerClockException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ManualLedgerClockService {
  const ManualLedgerClockService({
    required this.chatRepo,
    required this.snapshotRepo,
    required this.trackerRepo,
    required this.reconciliationRunRepo,
    required this.reconciliationCheckpointRepo,
    required this.proposalRunRepo,
  });

  final ChatRepo chatRepo;
  final TrackerSnapshotRepo snapshotRepo;
  final TrackerRepo trackerRepo;
  final LedgerReconciliationRunRepo reconciliationRunRepo;
  final LedgerReconciliationCheckpointRepo reconciliationCheckpointRepo;
  final CardEvolutionProposalRunRepo proposalRunRepo;

  Future<List<ManualLedgerClockEntry>> loadRecent(
    String sessionId, {
    int limit = 5,
  }) async {
    if (limit < 1) return const [];
    final session = await chatRepo.getById(sessionId);
    if (session == null) {
      throw const ManualLedgerClockException('Session not found');
    }
    final entries = <ManualLedgerClockEntry>[];
    for (var index = session.messages.length - 1; index >= 0; index--) {
      final message = session.messages[index];
      if (!_isEligible(message)) {
        continue;
      }
      final snapshot = await snapshotRepo.getByAnchor(
        sessionId: sessionId,
        messageId: message.id,
        swipeId: message.swipeId,
        agentSwipeId: message.agentSwipeId,
      );
      if (snapshot == null) continue;
      final clock = GameTimeState.fromTrackers(snapshot.trackers);
      if (clock.format() == null) continue;
      entries.add(
        ManualLedgerClockEntry(
          messageNumber: index + 1,
          messageId: message.id,
          swipeId: message.swipeId,
          agentSwipeId: message.agentSwipeId,
          committed: snapshot.committed,
          clock: clock,
        ),
      );
      if (entries.length >= limit) break;
    }
    return entries.reversed.toList(growable: false);
  }

  Future<void> save(
    String sessionId,
    List<ManualLedgerClockCorrection> corrections,
  ) async {
    if (corrections.isEmpty) return;
    _validateSequence(corrections.map((item) => item.clock));
    final changed = corrections
        .where((item) => !_sameClock(item.entry.clock, item.clock))
        .toList(growable: false);
    if (changed.isEmpty) return;
    final expectedIds = changed.map((item) => item.entry.messageId).toSet();
    if (expectedIds.length != changed.length) {
      throw const ManualLedgerClockException('Duplicate message correction');
    }
    final updatedAt = currentTimestampSeconds();
    final formattedById = {
      for (final correction in corrections)
        correction.entry.messageId: correction.clock.format()!,
    };
    final durable = await chatRepo.mutateMessagesWithBeforeWrite(
      sessionId: sessionId,
      updatedAt: updatedAt,
      mutate: (messages) {
        for (final correction in changed) {
          final index = messages.indexWhere(
            (message) => message.id == correction.entry.messageId,
          );
          if (index < 0) {
            throw const ManualLedgerClockException('Message changed');
          }
          final message = messages[index];
          if (!_isEligible(message) ||
              message.swipeId != correction.entry.swipeId ||
              message.agentSwipeId != correction.entry.agentSwipeId) {
            throw const ManualLedgerClockException('Message variation changed');
          }
          messages[index] = stampGameTimeForVariation(
            message,
            swipeId: correction.entry.swipeId,
            agentSwipeId: correction.entry.agentSwipeId,
            time: formattedById[message.id]!,
          );
        }
        return messages;
      },
      beforeWrite: (_, _) async {
        final currentWindow = await loadRecent(
          sessionId,
          limit: corrections.length + 1,
        );
        if (currentWindow.length < corrections.length) {
          throw const ManualLedgerClockException('Recent clock window changed');
        }
        final currentSelection = currentWindow.sublist(
          currentWindow.length - corrections.length,
        );
        for (var i = 0; i < corrections.length; i++) {
          final expected = corrections[i].entry;
          final current = currentSelection[i];
          if (current.messageId != expected.messageId ||
              current.swipeId != expected.swipeId ||
              current.agentSwipeId != expected.agentSwipeId ||
              current.committed != expected.committed ||
              !_sameClock(current.clock, expected.clock)) {
            throw const ManualLedgerClockException(
              'Recent clock window changed',
            );
          }
        }
        if (currentWindow.length > corrections.length) {
          _validateSequence([
            currentWindow[currentWindow.length - corrections.length - 1].clock,
            ...corrections.map((item) => item.clock),
          ]);
        }

        TrackerSnapshot? latestEditedSnapshot;
        GameTimeState? latestClock;
        for (final correction in changed) {
          final entry = correction.entry;
          final snapshot = await snapshotRepo.getByAnchor(
            sessionId: sessionId,
            messageId: entry.messageId,
            swipeId: entry.swipeId,
            agentSwipeId: entry.agentSwipeId,
          );
          if (snapshot == null ||
              snapshot.committed != entry.committed ||
              !_sameClock(
                GameTimeState.fromTrackers(snapshot.trackers),
                entry.clock,
              )) {
            throw const ManualLedgerClockException('Ledger snapshot changed');
          }
          await snapshotRepo.replaceGameClock(
            snapshot: snapshot,
            clock: correction.clock,
          );
          latestEditedSnapshot = snapshot;
          latestClock = correction.clock;
        }
        await proposalRunRepo.cancelPendingForMessageMutationInTransaction(
          sessionId: sessionId,
          messageIds: expectedIds,
          reason: 'manualClockEdit',
          now: updatedAt,
        );
        await reconciliationRunRepo.invalidateForMessageMutation(
          sessionId: sessionId,
          messageIds: expectedIds,
          reason: 'manual_clock_edit',
          createdAt: updatedAt,
        );
        await reconciliationCheckpointRepo.deleteForMessages(
          sessionId,
          expectedIds,
        );
        await trackerRepo.bumpLedgerManualMutationRevision(sessionId);

        final latestActive = await loadRecent(sessionId, limit: 1);
        if (latestActive.isNotEmpty &&
            latestEditedSnapshot != null &&
            latestActive.single.messageId == latestEditedSnapshot.messageId &&
            latestActive.single.swipeId == latestEditedSnapshot.swipeId &&
            latestActive.single.agentSwipeId ==
                latestEditedSnapshot.agentSwipeId) {
          await _writeLiveClock(sessionId, latestClock!, updatedAt);
        }
      },
    );
    if (durable == null) {
      throw const ManualLedgerClockException('Session changed');
    }
    ChatSessionService.updateCache(durable);
  }

  Future<void> _writeLiveClock(
    String sessionId,
    GameTimeState clock,
    int updatedAt,
  ) async {
    final values = <String, String>{
      GameTimeState.timeKey: clock.time!,
      GameTimeState.dateKey: clock.date!,
      GameTimeState.dayKey: '${clock.day}',
    };
    for (final entry in values.entries) {
      final current = await trackerRepo.get(sessionId, entry.key);
      await trackerRepo.upsert(
        Tracker(
          sessionId: sessionId,
          name: entry.key,
          value: entry.value,
          scope: current?.scope ?? 'ledger',
          provenance: 'manual_clock_edit',
          basisRevisionNumber: current?.basisRevisionNumber ?? 0,
          basisRevisionHash: current?.basisRevisionHash ?? '',
          updatedAt: updatedAt,
        ),
      );
    }
  }

  static bool _isEligible(ChatMessage message) =>
      message.role == 'assistant' &&
      !message.isHidden &&
      !message.isError &&
      !message.isTyping &&
      message.content.trim().isNotEmpty;

  static bool _sameClock(GameTimeState left, GameTimeState right) =>
      left.time == right.time &&
      left.date == right.date &&
      left.day == right.day;

  static void _validateSequence(Iterable<GameTimeState> values) {
    GameTimeState? previous;
    for (final value in values) {
      if (value.format() == null) {
        throw const ManualLedgerClockException('Invalid game clock');
      }
      if (previous != null && _isBefore(value, previous)) {
        throw const ManualLedgerClockException(
          'Game clock must not move backward',
        );
      }
      if (previous != null && !_calendarMatchesRpDay(previous, value)) {
        throw const ManualLedgerClockException(
          'Calendar date and RP day must advance together',
        );
      }
      previous = value;
    }
  }

  static bool _isBefore(GameTimeState value, GameTimeState previous) {
    if (value.day! < previous.day!) return true;
    return _dateTimeValue(value).isBefore(_dateTimeValue(previous));
  }

  static bool _calendarMatchesRpDay(
    GameTimeState previous,
    GameTimeState value,
  ) {
    final calendarDays =
        _dateTimeValue(
              GameTimeState(time: '00:00', date: value.date, day: value.day),
            )
            .difference(
              _dateTimeValue(
                GameTimeState(
                  time: '00:00',
                  date: previous.date,
                  day: previous.day,
                ),
              ),
            )
            .inDays;
    return calendarDays == value.day! - previous.day!;
  }

  static DateTime _dateTimeValue(GameTimeState value) {
    final date = value.date!.split('.').map(int.parse).toList(growable: false);
    final time = value.time!.split(':').map(int.parse).toList(growable: false);
    return DateTime.utc(date[2], date[1], date[0], time[0], time[1]);
  }
}
