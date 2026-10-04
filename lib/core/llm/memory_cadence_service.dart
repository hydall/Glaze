import '../db/repositories/memory_cadence_repo.dart';
import '../models/memory_book.dart';
import 'memory_retrieval_mode.dart';

/// Cadence gating service (Phase G4).
///
/// Determines whether post-turn memory work (graph rebuild, salience rescore,
/// consolidation) should run based on the number of assistant messages since
/// the last run and the configured [MemoryBookSettings.cadenceInterval].
///
/// Enabled only for enriched modern modes. Fast and the separate Legacy
/// rollback path do not run enrichment cadence work.
class MemoryCadenceService {
  final MemoryCadenceRepo _cadenceRepo;

  const MemoryCadenceService(this._cadenceRepo);

  Future<bool> shouldRun(
    String sessionId,
    String kind, {
    required String memoryMode,
    required int cadenceInterval,
  }) async {
    if (!MemoryRetrievalMode.fromValue(
      memoryMode,
    ).supports(MemoryRetrievalCapability.salienceEnrichment)) {
      return false;
    }
    if (cadenceInterval <= 0) return false;
    return _cadenceRepo.shouldRun(sessionId, kind, cadenceInterval);
  }

  Future<void> markRun(String sessionId, String kind) {
    return _cadenceRepo.reset(sessionId, kind);
  }

  Future<void> incrementAssistant(String sessionId) {
    return _cadenceRepo.incrementAssistant(sessionId);
  }
}
