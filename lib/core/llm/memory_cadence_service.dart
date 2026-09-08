import '../db/repositories/memory_cadence_repo.dart';
import '../models/memory_book.dart';

/// Cadence gating service (Phase G4).
///
/// Determines whether post-turn memory work (graph rebuild, salience rescore,
/// consolidation) should run based on the number of assistant messages since
/// the last run and the configured [MemoryBookSettings.cadenceInterval].
///
/// Disabled entirely in `fast` mode (decision D).
class MemoryCadenceService {
  final MemoryCadenceRepo _cadenceRepo;

  const MemoryCadenceService(this._cadenceRepo);

  Future<bool> shouldRun(
    String sessionId,
    String kind, {
    required String memoryMode,
    required int cadenceInterval,
  }) async {
    if (memoryMode == 'fast') return false;
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
