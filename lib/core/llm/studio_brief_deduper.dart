import '../models/studio_config.dart';
import 'studio_brief_parser.dart';
import 'studio_stage_brief.dart';

/// Cross-brief dedup + meta-policy sanitization for the final-stage briefs,
/// extracted from `MemoryStudioService` (plan §2).
///
/// Pure aside from the injected [StudioBriefParser] (reused for heading/item
/// recognition and meta sanitization). Behavior preserved verbatim.
class StudioBriefDeduper {
  final StudioBriefParser _parser;

  StudioBriefDeduper(this._parser);

  /// Remove cross-controller duplicate bullet points before sending briefs to
  /// the final responder. The first controller to mention a point keeps it;
  /// later controllers drop the duplicate. Meta briefs are passed through
  /// unchanged.
  List<StudioStageBrief> dedupePriorBriefs(List<StudioStageBrief> briefs) {
    final seen = <String>{};
    final result = <StudioStageBrief>[];
    for (final brief in briefs) {
      if (_parser.isMetaBriefName(brief.agentName)) {
        result.add(brief);
        continue;
      }
      final deduped = _dedupeBriefBody(brief.brief, seen);
      result.add(
        StudioStageBrief(
          agentId: brief.agentId,
          agentName: brief.agentName,
          brief: deduped,
          status: brief.status,
          error: brief.error,
          refreshPolicy: brief.refreshPolicy,
          cacheKey: brief.cacheKey,
          cacheHit: brief.cacheHit,
        ),
      );
    }
    return result;
  }

  /// Walk the Focus/Constraints/Avoid sections of one brief, dropping any
  /// bullet whose normalized form was already emitted by an earlier brief.
  /// Empty sections are removed. [seen] accumulates across briefs.
  String _dedupeBriefBody(String brief, Set<String> seen) {
    final lines = brief.split('\n');
    final out = <String>[];
    var currentHeading = '';
    final pendingHeadingItems = <String>[];

    void flushHeading() {
      if (currentHeading.isEmpty) return;
      if (pendingHeadingItems.isNotEmpty) {
        out.add(currentHeading);
        out.addAll(pendingHeadingItems);
      }
      currentHeading = '';
      pendingHeadingItems.clear();
    }

    for (final rawLine in lines) {
      final line = rawLine.trimRight();
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final heading = _parser.studioBriefHeading(trimmed);
      if (heading != null) {
        flushHeading();
        currentHeading = line;
        continue;
      }
      final item = _parser.cleanBriefItem(trimmed);
      if (item == null) {
        // Non-bullet line outside a known section; keep verbatim once.
        final key = 'raw:${_dedupeKey(trimmed)}';
        if (seen.add(key)) {
          if (currentHeading.isNotEmpty) {
            pendingHeadingItems.add(line);
          } else {
            out.add(line);
          }
        }
        continue;
      }
      final key = _dedupeKey(item);
      if (!seen.add(key)) continue;
      pendingHeadingItems.add('- $item');
    }
    flushHeading();
    return out.join('\n').trim();
  }

  String _dedupeKey(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9а-яё ]', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Sanitize a single prior brief for the final stage: meta briefs get the
  /// canonical meta-policy text; others are re-parsed through the brief parser
  /// against their owning agent.
  StudioStageBrief sanitizePriorBriefForFinal(
    StudioStageBrief brief,
    StudioConfig config,
  ) {
    if (!_parser.isMetaBriefName(brief.agentName)) {
      final agent = _agentForBrief(brief, config);
      return StudioStageBrief(
        agentId: brief.agentId,
        agentName: brief.agentName,
        brief: _parser.sanitizeIntermediateAgentOutput(agent, brief.brief),
        status: brief.status,
        error: brief.error,
        refreshPolicy: brief.refreshPolicy,
        cacheKey: brief.cacheKey,
        cacheHit: brief.cacheHit,
      );
    }
    return StudioStageBrief(
      agentId: brief.agentId,
      agentName: brief.agentName,
      brief: _parser.sanitizeMetaBrief(brief.brief),
      status: brief.status,
      error: brief.error,
      refreshPolicy: brief.refreshPolicy,
      cacheKey: brief.cacheKey,
      cacheHit: brief.cacheHit,
    );
  }

  StudioAgent _agentForBrief(StudioStageBrief brief, StudioConfig config) {
    return config.agents.firstWhere(
      (agent) => agent.id == brief.agentId || agent.name == brief.agentName,
      orElse: () => StudioAgent(id: brief.agentId, name: brief.agentName),
    );
  }
}
