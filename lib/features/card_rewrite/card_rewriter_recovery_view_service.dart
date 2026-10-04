import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/app_db.dart';
import '../../core/db/repositories/card_evolution_writer_call_repo.dart';
import '../../core/state/db_provider.dart';

final class CardRewriterRecoveryView {
  const CardRewriterRecoveryView({required this.claim, required this.calls});

  final CardEvolutionClaimRow claim;
  final List<CardEvolutionWriterCallRow> calls;

  CardEvolutionWriterCallRow? get frontier =>
      calls.where((call) => call.status != 'completed').firstOrNull;

  int get completedCount =>
      calls.where((call) => call.status == 'completed').length;
}

final class CardRewriterRecoveryViewService {
  const CardRewriterRecoveryViewService({required this.writerCallRepo});

  final CardEvolutionWriterCallRepo writerCallRepo;

  Future<List<CardRewriterRecoveryView>> load(String sessionId) async {
    final claims = await writerCallRepo.readFailedClaims(sessionId);
    return Future.wait(
      claims.map(
        (claim) async => CardRewriterRecoveryView(
          claim: claim,
          calls: await writerCallRepo.readChain(claim.id),
        ),
      ),
    );
  }
}

final cardRewriterRecoveryViewServiceProvider =
    Provider<CardRewriterRecoveryViewService>((ref) {
      return CardRewriterRecoveryViewService(
        writerCallRepo: ref.watch(cardEvolutionWriterCallRepoProvider),
      );
    });

final cardRewriterRecoveryViewsProvider = FutureProvider.autoDispose
    .family<List<CardRewriterRecoveryView>, String>((ref, sessionId) {
      return ref.watch(cardRewriterRecoveryViewServiceProvider).load(sessionId);
    });
