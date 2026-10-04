import 'package:drift/drift.dart';

import '../../utils/time_helpers.dart';
import '../app_db.dart';
import 'card_evolution_selected_input_validator.dart';

final class CardEvolutionProposalRunRepo {
  const CardEvolutionProposalRunRepo(this.db);

  final AppDatabase db;

  Future<List<String>> cancelPendingForMessageMutationInTransaction({
    required String sessionId,
    required Set<String> messageIds,
    String reason = 'chatEvidenceChanged',
    int? now,
  }) async {
    if (messageIds.isEmpty) return const [];
    final proposals = await (db.select(
      db.cardEvolutionProposalRuns,
    )..where((row) => row.sessionId.equals(sessionId))).get();
    final cancelled = <String>[];
    for (final proposal in proposals) {
      final evidence = CardEvolutionSelectedChatEvidence.tryParse(
        proposal.selectedInputJson,
      );
      if (evidence != null && !evidence.referencesAny(messageIds)) continue;
      final job =
          await (db.select(db.rewriteJobs)..where(
                (row) =>
                    row.id.equals(proposal.rewriteJobId) &
                    row.chatSessionId.equals(sessionId) &
                    row.characterId.equals(proposal.characterId) &
                    row.status.equals('pending'),
              ))
              .getSingleOrNull();
      if (job == null) continue;
      final changed =
          await (db.update(db.rewriteJobs)..where(
                (row) =>
                    row.id.equals(proposal.rewriteJobId) &
                    row.chatSessionId.equals(sessionId) &
                    row.characterId.equals(proposal.characterId) &
                    row.status.equals('pending') &
                    row.version.equals(job.version),
              ))
              .write(
                RewriteJobsCompanion(
                  status: const Value('cancelled'),
                  statusReason: Value(reason),
                  version: Value(job.version + 1),
                  updatedAt: Value(now ?? currentTimestampSeconds()),
                ),
              );
      if (changed == 1) cancelled.add(proposal.rewriteJobId);
    }
    return cancelled;
  }

  Future<bool> cancelPendingJobInTransaction({
    required CardEvolutionProposalRunRow proposal,
    String reason = 'chatEvidenceChanged',
    int? now,
  }) async {
    final job =
        await (db.select(db.rewriteJobs)..where(
              (row) =>
                  row.id.equals(proposal.rewriteJobId) &
                  row.chatSessionId.equals(proposal.sessionId) &
                  row.characterId.equals(proposal.characterId) &
                  row.status.equals('pending'),
            ))
            .getSingleOrNull();
    if (job == null) return false;
    final changed =
        await (db.update(db.rewriteJobs)..where(
              (row) =>
                  row.id.equals(proposal.rewriteJobId) &
                  row.chatSessionId.equals(proposal.sessionId) &
                  row.characterId.equals(proposal.characterId) &
                  row.status.equals('pending') &
                  row.version.equals(job.version),
            ))
            .write(
              RewriteJobsCompanion(
                status: const Value('cancelled'),
                statusReason: Value(reason),
                version: Value(job.version + 1),
                updatedAt: Value(now ?? currentTimestampSeconds()),
              ),
            );
    return changed == 1;
  }
}
