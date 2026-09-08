import 'dart:math';

import '../models/memory_book.dart';
import '../models/memory_graph.dart';
import '../utils/time_helpers.dart';

/// Heuristic salience scorer (Phase G1). 0 LLM calls.
///
/// Combines emotional signals, narrative flags, entry importance, and length
/// into a 0..1 score. Entries with [isCore] true receive core memory
/// protection in [MemorySelector] (5x slower decay, floor 0.5).
class MemorySalienceScorer {
  const MemorySalienceScorer._();

  static const _emotionalPatterns = <String, List<String>>{
    'grief': ['grief', 'grieved', 'mourning', 'mourn', 'sorrow', 'lament'],
    'betrayal': ['betray', 'betrayed', 'betrayal', 'backstab'],
    'tension': ['tension', 'tense', 'suspicion', 'suspicious', 'distrust'],
    'dread': ['dread', 'dreaded', 'horror', 'terror', 'afraid', 'fear'],
    'joy': ['joy', 'joyful', 'happiness', 'happy', 'elated', 'triumph'],
    'resolve': ['resolve', 'resolved', 'determination', 'determined'],
    'humor': ['humor', 'humorous', 'laugh', 'laughed', 'amused', 'witty'],
    'intimacy': ['intimacy', 'intimate', 'tender', 'caress', 'embrace'],
  };

  static const _narrativePatterns = <String, List<String>>{
    'death': ['death', 'died', 'dead', 'killed', 'slain', 'killing', 'murder'],
    'promise': ['promise', 'promised', 'vow', 'vowed', 'oath', 'swore'],
    'confession': ['confession', 'confessed', 'admitted', 'confess'],
    'first_meeting': ['first meeting', 'first met', 'first saw', 'first time they met'],
    'battle': ['battle', 'fought', 'fight', 'combat', 'skirmish', 'ambush'],
    'discovery': ['discovered', 'discovery', 'found out', 'uncovered', 'revealed'],
    'departure': ['departure', 'departed', 'left', 'leaving', 'farewell', 'goodbye'],
  };

  /// Scores a [MemoryEntry] and returns a [MemorySalience] record.
  static MemorySalience score(
    MemoryEntry entry, {
    required String sessionId,
    int? nowSeconds,
  }) {
    final now = nowSeconds ?? currentTimestampSeconds();
    final text = '${entry.title} ${entry.content}'.toLowerCase();
    final wordCount = entry.content.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

    final emotionalTags = <String>[];
    var emotionalComponent = 0.0;
    for (final entry_ in _emotionalPatterns.entries) {
      if (entry_.value.any((p) => text.contains(p))) {
        emotionalTags.add(entry_.key);
      }
    }
    if (emotionalTags.any((t) =>
        t == 'grief' || t == 'betrayal' || t == 'tension' || t == 'dread')) {
      emotionalComponent = 0.3;
    } else if (emotionalTags
        .any((t) => t == 'joy' || t == 'resolve' || t == 'humor')) {
      emotionalComponent = 0.2;
    }

    final narrativeFlags = <String>[];
    var narrativeComponent = 0.0;
    for (final entry_ in _narrativePatterns.entries) {
      if (entry_.value.any((p) => text.contains(p))) {
        narrativeFlags.add(entry_.key);
      }
    }
    if (narrativeFlags
        .any((f) => f == 'death' || f == 'promise' || f == 'confession')) {
      narrativeComponent = 0.4;
    } else if (narrativeFlags.any((f) =>
        f == 'first_meeting' ||
        f == 'battle' ||
        f == 'discovery' ||
        f == 'departure')) {
      narrativeComponent = 0.2;
    }

    final importanceComponent = (entry.importance.clamp(0, 1)) * 0.3;
    final lengthComponent = min(0.1, wordCount / 500);

    final score = (emotionalComponent +
            narrativeComponent +
            importanceComponent +
            lengthComponent)
        .clamp(0.0, 1.0);

    final hasDialogue = RegExp(r'"[^"]*"|"[^"]*"').hasMatch(entry.content);
    final hasAction = RegExp(r'\b(said|walked|ran|grabbed|struck|looked|turned|stepped|reached)\b')
        .hasMatch(entry.content.toLowerCase());

    return MemorySalience(
      id: 'salience_${entry.id}',
      chatSessionId: sessionId,
      memoryEntryId: entry.id,
      score: score,
      emotionalTags: emotionalTags,
      narrativeFlags: narrativeFlags,
      hasDialogue: hasDialogue,
      hasAction: hasAction,
      wordCount: wordCount,
      scoreSource: 'heuristic',
      scoredAt: now,
      createdAt: now,
    );
  }

  /// An entry is "core" if its salience is high or it involves death/promise.
  /// Core entries receive 5x slower temporal decay in [MemorySelector].
  static bool isCore(MemorySalience? salience) {
    if (salience == null) return false;
    return salience.score > 0.7 ||
        salience.narrativeFlags.contains('death') ||
        salience.narrativeFlags.contains('promise');
  }
}
