import 'game_time.dart';

/// Request-local framing; never persisted in memory bodies or embeddings.
String historicalMemoryHeader(GameTimeState clock) =>
    '[Historical evidence, not current state]\n'
    '${currentStoryPoint(clock)}\n'
    'Each passage describes its own story point. Present tense is local to '
    'that point: do not infer that people, possessions, relationships, or '
    'conditions remain unchanged now. Current Ledger canon and Character '
    'Knowledge take precedence; accepted historical evidence overrides a '
    'conflicting card baseline. Preserve who observed, believed, or learned '
    'each claim; a recalled statement is not necessarily objective truth.';

String currentStoryPoint(GameTimeState clock) {
  final parts = <String>[
    if (clock.day != null) 'day ${clock.day}',
    if (clock.date?.trim().isNotEmpty == true) clock.date!.trim(),
    if (clock.time?.trim().isNotEmpty == true) clock.time!.trim(),
  ];
  return 'Current story point: ${parts.isEmpty ? 'unknown' : parts.join(' | ')}';
}

String memoryOccurrence(String? range) {
  final value = range?.trim() ?? '';
  return 'Occurred: ${value.isEmpty ? 'story time unknown' : value}';
}
