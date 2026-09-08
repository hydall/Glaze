import '../studio_brief_cache.dart';
import '../studio_brief_parser.dart';
import '../studio_stage_brief.dart';
import '../tracker_batcher.dart';
import '../../models/studio_config.dart';

/// Maps [TrackerBatchResult]s into [StudioStageBrief]s and detects the first
/// failure in a batch result list. Extracted from `MemoryStudioService`
/// (plan Phase 5a) as a pure-logic specialist with no `Ref`.
///
/// Deps: [StudioBriefParser] for sanitizing intermediate agent output,
/// [StudioBriefCache] for `isCacheablePolicy` (cache-key inclusion).
class StudioTrackerResultMapper {
  final StudioBriefParser _briefParser;
  final StudioBriefCache _briefCache;

  StudioTrackerResultMapper(this._briefParser, this._briefCache);

  /// Returns the first result whose `status != 'ok'` or whose `text` is empty,
  /// or `null` if all results are OK with non-empty text.
  TrackerBatchResult? firstFailedTrackerResult(List<TrackerBatchResult> results) {
    for (final result in results) {
      if (result.status != 'ok' || result.text.trim().isEmpty) {
        return result;
      }
    }
    return null;
  }

  /// Converts batch results into [StudioStageBrief]s (used for the error path
  /// when the cycle fails — produces briefs for the partial results so the UI
  /// can display what was produced before the failure).
  List<StudioStageBrief> trackerResultsToBriefs(
    List<TrackerBatchResult> results,
    List<StudioAgent> dueTrackers,
    Map<String, CacheProbe> cacheProbeByAgent,
  ) {
    final briefs = <StudioStageBrief>[];
    for (final result in results) {
      final probe = cacheProbeByAgent[result.agentId];
      final agent = dueTrackers.firstWhere((a) => a.id == result.agentId);
      final sanitized = result.status == 'ok'
          ? _briefParser.sanitizeIntermediateAgentOutput(agent, result.text)
          : result.text;
      briefs.add(
        StudioStageBrief(
          agentId: result.agentId,
          agentName: result.agentName,
          brief: sanitized,
          status: result.status,
          error: result.error,
          refreshPolicy: probe?.policy ?? 'turn',
          cacheKey: _briefCache.isCacheablePolicy(probe?.policy ?? 'turn')
              ? probe?.cacheKey
              : null,
          cacheHit: false,
        ),
      );
    }
    return briefs;
  }

  /// Formats the user-facing error message for a failed tracker result.
  String trackerFailureMessage(TrackerBatchResult result) {
    final reason = result.error ?? 'missing or unparseable tracker result';
    return 'Studio tracker "${result.agentName}" failed after 2 retries: '
        '$reason. Please restart generation.';
  }
}
