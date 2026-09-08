import '../models/preset.dart';

/// Pure block-classification specialist extracted from
/// `StudioDecompositionService` (plan §3). Decides, deterministically (the
/// keyword fallback used when the LLM router is unavailable), which controller
/// bucket a preset block belongs to, whether it is a reasoning/CoT template
/// (dropped before routing), and whether it is a cross-cutting "broadcast"
/// rule (duplicated into the final responder + persisted for the POST-cleaner).
///
/// Has no `Ref` and no state. Behavior is preserved verbatim from the original
/// methods. The service keeps static `@visibleForTesting` delegators for
/// [isReasoningBlock] and [isBroadcastBlock] because tests reference them via
/// `StudioDecompositionService.<name>`.
class StudioBlockClassifier {
  StudioBlockClassifier._();

  /// True if a block is a chain-of-thought / reasoning / thinking template.
  /// Such blocks describe HOW to reason internally; the multi-agent pipeline
  /// already externalizes reasoning, so they are dropped before routing rather
  /// than assigned to an agent.
  ///
  /// This is the deterministic fallback used when the LLM router is
  /// unavailable. It is intentionally conservative: a block that merely
  /// *mentions* a `<think>` block is NOT reasoning. When in doubt, keep the
  /// block (return false) so the router/keyword bucketing can still place it.
  static bool isReasoningBlock(PresetBlock block) {
    final name = block.name.toLowerCase();
    final id = block.id.toLowerCase();

    // Strong name/id signals (cheap, high-precision).
    const nameNeedles = [
      'cot',
      'chain of thought',
      'chain-of-thought',
      'reasoning',
      'think template',
      'thinking',
      '<think>',
    ];
    for (final needle in nameNeedles) {
      if (name.contains(needle) || id.contains(needle)) return true;
    }

    return _contentIsReasoningTemplate(block.content);
  }

  /// Content-based reasoning detection. Distinguishes a block that IS a
  /// reasoning/CoT template from one that merely references `<think>`.
  ///
  /// Two positive signals:
  /// 1. The block is *dominated* by think-tag content — most of the block lives
  ///    inside the reasoning tags (a real CoT scaffold).
  /// 2. The block actively *directs the model to produce* a think block (an
  ///    action verb tied to the tag, e.g. `use`, `plan internally`, `before
  ///    replying`). A passive description (the think block "stays English") is
  ///    excluded.
  static bool _contentIsReasoningTemplate(String content) {
    if (content.isEmpty) return false;
    final lower = content.toLowerCase();
    if (!lower.contains('<think>')) return false;

    // Signal 1: think tags dominate the block.
    final insideThink = RegExp(
      r'<think>([\s\S]*?)</think>',
      caseSensitive: false,
    );
    var insideChars = 0;
    for (final m in insideThink.allMatches(content)) {
      insideChars += (m.group(1) ?? '').length;
    }
    final ratio = insideChars / content.length;
    if (ratio >= _reasoningDominanceRatio) return true;

    // Signal 2: an explicit directive to emit a <think> reasoning block. These
    // patterns require an action verb tied to the tag, so passive mentions
    // ("after </think>", "the <think> block remains English") do not match.
    const directivePatterns = [
      r'use\s+<think>',
      r'<think>[^<]*</think>\s*(?:for|to)\b',
      r'(?:plan|think|reason)\s+(?:internally|step[- ]by[- ]step)[^.]*<think>',
      r'(?:before|prior to)\s+(?:replying|responding|answering)[^.]*<think>',
      r'wrap\s+(?:your\s+)?(?:reasoning|planning|thinking)\s+in\s+<think>',
    ];
    for (final p in directivePatterns) {
      if (RegExp(p, caseSensitive: false).hasMatch(lower)) return true;
    }
    return false;
  }

  /// Fraction of a block that must live inside `<think>...</think>` for the
  /// block to count as a reasoning template via signal 1.
  static const double _reasoningDominanceRatio = 0.4;

  /// True if a block carries a cross-cutting rule that must be broadcast to the
  /// final responder and the POST-cleaner in addition to its primary agent:
  /// output language/format rules and prose-quality guards (anti-loop /
  /// anti-echo / anti-cliché / anti-slop / banlists).
  static bool isBroadcastBlock(PresetBlock block) {
    if (isReasoningBlock(block)) return false;
    final text = '${block.name}\n${block.id}\n${block.content}'.toLowerCase();
    const needles = [
      // Output language / format rules.
      'language',
      'русск',
      'russian',
      'output_language',
      // Response length / paragraph budget (cross-cutting: governs final
      // reply AND POST-cleaner rewrite length).
      'length:',
      'length_rules',
      'length_target',
      'длинный ответ',
      'короткий ответ',
      'средний ответ',
      // Prose-quality guards.
      'anti-loop',
      'anti loop',
      'anti-echo',
      'anti echo',
      'anti-cliche',
      'anti-clich',
      'анти-клише',
      'анти-луп',
      'анти-эхо',
      'anti-slop',
      'slop',
      'ban rus',
      'banlist',
      'forbidden words',
    ];
    return _containsAny(text, needles);
  }

  /// Deterministic keyword bucketing: maps a block to one of the controller
  /// ids (`meta`, `agency`, `guard`, `dialogue`, `world`, `beauty`,
  /// `narrative`, `continuity`, `final`). Used when the LLM router is unavailable or did not
  /// classify the block.
  static String bucketForBlock(PresetBlock block) {
    final text = '${block.name}\n${block.id}\n${block.content}'.toLowerCase();
    final id = block.id.toLowerCase();

    if (_containsAny(text, const [
      'lumia',
      'ghost in the machine',
      'meta-weaver',
      'meta weaver',
      'ooc interface',
      'ooc policy',
      'weaver',
      'diagnostic',
    ])) {
      return 'meta';
    }
    if (_containsAny(text, const [
      'never write for',
      'user autonomy',
      'human controls user',
      'do not write {{user}}',
      'sovereignty',
    ])) {
      return 'agency';
    }
    if (_containsAny(text, const [
      'character autonomy',
      'character foundation',
      'behavioral realism',
      'anti-deitism',
      'character voice',
      'emotional response realism',
      'psychology',
      'personality drives',
    ])) {
      return 'agency';
    }
    if (_containsAny(text, const [
      'anti-loop',
      'anti loop',
      'anti-echo',
      'anti echo',
      'anti-cliche',
      'anti-clich',
      'anti-slop',
      'ban rus',
      'forbidden words',
      'no tells',
      'repetition repair',
      'hard slop ban',
    ])) {
      return 'guard';
    }
    if (_isBeautySettingsBlock(text)) {
      return 'beauty';
    }
    if (_containsAny(text, const [
      'dialogue',
      'monologue',
      'speech',
      'voice utility',
      'interaction',
      'pure-dialogue',
      'let dialogue breathe',
    ])) {
      return 'dialogue';
    }
    if (_containsAny(text, const [
      'npc',
      'living world',
      'world canvas',
      'ambient',
      'public spaces',
      'offscreen',
      'background activity',
    ])) {
      return 'world';
    }
    if (_containsAny(text, const [
      'story mode',
      'narrative',
      'pacing',
      'length',
      'paragraph',
      'word',
      'sensory',
      'pov',
      'third person',
      'style',
      'poetic',
      'flowing prose',
      'writer style',
      'ao3',
      'tone',
      'genre',
      'romantic',
      'fluff',
      'slow-burn',
      'difficulty',
      'momentum',
      'temporal',
      'focus lock',
    ])) {
      return 'narrative';
    }
    if (_containsAny(text, const [
          'scenario',
          'persona',
          'description',
          'personality',
          'memory',
          'summary',
          'lorebook',
          'ground truth',
          'continuity',
          'who knows what',
          'facts',
        ]) ||
        const {
          'char_card',
          'char_personality',
          'user_persona',
          'scenario',
          'example_dialogue',
          'summary',
          'memory',
        }.contains(id)) {
      return 'continuity';
    }
    if (_containsAny(text, const [
      'language',
      'format',
      'relationship metrics',
      'comics',
      'nsfw',
      'mature',
      'explicit',
      'professional context',
      'test_mode',
      'internal_test',
      'content protocol',
    ])) {
      return 'final';
    }
    return 'final';
  }

  static bool _containsAny(String text, List<String> needles) {
    return needles.any(text.contains);
  }

  /// Beauty Shard owns reusable styling variables, not concrete widgets.
  /// Route color/font/palette/CSS settings there, but keep one-off HTML
  /// artifacts (phone screens, taxi menus, terminals), trackers/infoblocks,
  /// and image-gen blocks out of Beauty.
  static bool _isBeautySettingsBlock(String text) {
    if (_containsAny(text, const [
      '<infoblock',
      '<general_stats',
      '<secondary_infoblock',
      '<loomledger',
      'tracker',
      'stats panel',
      'relationship metrics',
      'pregnancy',
      'cycle',
      'topbar',
      'infoboard',
      '[inbd:',
      '[tpbr:',
      '[img:gen',
      'data-iig-instruction',
      '<illustration',
      '<comics',
      'image generation',
      'image prompt',
      'visual html card',
    ])) {
      return false;
    }
    if (_containsAny(text, const [
      'phone screen',
      'smartphone',
      'taxi',
      'call menu',
      'terminal',
      'hud',
      'scroll',
      'sign, a button, a note',
      'scene-object',
      'artifact protocol',
      'diegetic html',
      'screen, hud, scroll, sign',
      'checkbox hack',
      'carousel',
      'page flip',
    ])) {
      return false;
    }
    return _containsAny(text, const [
      'glaze_beauty_state',
      'beauty shard',
      'styling state',
      'color scheme',
      'colour scheme',
      'speaker color',
      'speaker colour',
      'dialogue color',
      'dialogue colour',
      'thought color',
      'thought colour',
      'reuse colors',
      'reuse colours',
      'reuse the color',
      'font color',
      'font-family',
      'font family',
      '<font color',
      '<font style',
      'background color',
      'background-color',
      'palette',
      'gradient',
      'text-shadow',
      'letter-spacing',
      'typography',
      'visual text effects',
      'text transforms',
      'signature micro-text',
      'reserved color',
      'bunnymo <font',
    ]);
  }
}
