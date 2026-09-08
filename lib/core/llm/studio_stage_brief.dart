/// One stage in the Studio pipeline: a tracker brief or the final generator
/// response. Carries cache metadata so the orchestrator can decide whether to
/// skip the LLM call for a cached tracker.
///
/// Pure DTO — no dependencies. Extracted from `memory_studio_service.dart` so
/// the brief cache, deduper, and service can all reference it without import
/// cycles.
class StudioStageBrief {
  final String agentId;
  final String agentName;
  final String brief;
  final String status;
  final String? error;
  final String refreshPolicy;
  final String? cacheKey;
  final bool cacheHit;

  const StudioStageBrief({
    required this.agentId,
    required this.agentName,
    required this.brief,
    this.status = 'ok',
    this.error,
    this.refreshPolicy = 'turn',
    this.cacheKey,
    this.cacheHit = false,
  });

  StudioStageBrief copyWithCacheMetadata({
    required String refreshPolicy,
    String? cacheKey,
    bool cacheHit = false,
  }) {
    return StudioStageBrief(
      agentId: agentId,
      agentName: agentName,
      brief: brief,
      status: status,
      error: error,
      refreshPolicy: refreshPolicy,
      cacheKey: cacheKey,
      cacheHit: cacheHit,
    );
  }
}
