/// Prompt Block Router for Studio Mode (Phase 11).
///
/// Classifies enabled preset blocks into stage-specific instruction shards.
/// Each Studio stage receives only the shards it needs plus compact briefs
/// from earlier stages — never the full enabled preset.
///
/// Classification is deterministic (by block name/category) with user override
/// in Advanced settings. This prevents sending the full preset to every agent.
class PromptBlockRouter {
  const PromptBlockRouter._();

  /// Categories that each stage receives.
  static const Map<StudioStage, Set<String>> stageShards = {
    StudioStage.memoryCurator: {'memory', 'continuity'},
    StudioStage.scenarioWriter: {'scenario', 'continuity'},
    StudioStage.director: {'director', 'style', 'continuity'},
    StudioStage.operator: {'operator', 'staging'},
    StudioStage.mainResponder: {'style', 'prose', 'intimacy', 'violence', 'utility', 'final'},
  };

  /// Classify a block name into a shard category.
  /// Deterministic mapping based on common preset block naming conventions.
  static String classifyBlock(String blockName, {String? category}) {
    final lower = blockName.toLowerCase();

    // Memory / continuity — memory checked first (more specific)
    if (lower.contains('memory') || lower.contains('recall')) return 'memory';

    // Scenario / arc — checked before continuity (arc is more specific to scenario)
    if (lower.contains('scenario') || lower.contains('arc') ||
        lower.contains('plot') || lower.contains('quest') ||
        lower.contains('story')) {
      return 'scenario';
    }

    // Continuity (state, tracker, relationship)
    if (lower.contains('continuity') || lower.contains('tracker') ||
        lower.contains('state') || lower.contains('relationship')) {
      return 'continuity';
    }

    // Director
    if (lower.contains('director') || lower.contains('tone') ||
        lower.contains('pacing') || lower.contains('mood')) {
      return 'director';
    }

    // Operator / staging
    if (lower.contains('operator') || lower.contains('staging') ||
        lower.contains('camera') || lower.contains('blocking') ||
        lower.contains('sensory')) {
      return 'operator';
    }

    // Style / prose
    if (lower.contains('style') || lower.contains('prose') ||
        lower.contains('writing') || lower.contains('language')) {
      return 'style';
    }

    // Intimacy / violence
    if (lower.contains('intimacy') || lower.contains('romance') ||
        lower.contains('nsfw')) {
      return 'intimacy';
    }
    if (lower.contains('violence') || lower.contains('combat') ||
        lower.contains('action')) {
      return 'violence';
    }

    // Utility / OOC
    if (lower.contains('utility') || lower.contains('ooc') ||
        lower.contains('system') || lower.contains('instruction')) {
      return 'utility';
    }

    // Default: final-only (main responder gets it)
    if (category != null) return category;
    return 'final';
  }

  /// Filter preset blocks for a specific stage.
  /// Returns only the blocks whose shard category matches the stage.
  static List<PresetBlockShard> filterForStage(
    StudioStage stage,
    List<PresetBlockInfo> blocks,
  ) {
    final allowedShards = stageShards[stage] ?? const {};
    return blocks
        .where((b) => allowedShards.contains(b.shard))
        .map((b) => PresetBlockShard(
              name: b.name,
              content: b.content,
              shard: b.shard,
            ))
        .toList();
  }
}

enum StudioStage {
  memoryCurator,
  summarizer,
  trackerUpdater,
  scenarioWriter,
  director,
  operator,
  mainResponder,
}

class PresetBlockInfo {
  final String name;
  final String content;
  final String shard;

  const PresetBlockInfo({
    required this.name,
    required this.content,
    required this.shard,
  });

  factory PresetBlockInfo.classify(String name, String content, {String? category}) {
    return PresetBlockInfo(
      name: name,
      content: content,
      shard: PromptBlockRouter.classifyBlock(name, category: category),
    );
  }
}

class PresetBlockShard {
  final String name;
  final String content;
  final String shard;

  const PresetBlockShard({
    required this.name,
    required this.content,
    required this.shard,
  });
}
