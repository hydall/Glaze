import '../models/memory_book.dart';
import 'game_time.dart';
import 'memory_excerpt_selector.dart';
import 'memory_temporal_context.dart';

/// Formats [MemoryInjectionItem]s into the canonical memory block text used
/// by the prompt builder, memory injection service, and isolate worker.
///
/// Set [includeContextHeader] to `true` to prepend a `Memory context:` header
/// (used for the `{{memory}}` macro / hard-block injection).
String formatMemoryItems(
  List<MemoryInjectionItem> items, {
  required bool includeContextHeader,
  GameTimeState gameTime = const GameTimeState(),
}) {
  final parts = <String>[];
  if (includeContextHeader) {
    parts.add('Memory context:');
  }
  if (items.isNotEmpty) parts.add(historicalMemoryHeader(gameTime));
  for (final item in items) {
    final title = item.entry.title.isNotEmpty
        ? item.entry.title
        : formatMemoryRange(item.entry) ?? 'Memory';
    final range = formatMemoryRange(item.entry);
    final heading = range == null || range == title
        ? 'Memory: $title'
        : 'Memory: $title ($range)';
    final ledger = item.entry.ledgerRange.trim();
    final metadata = '\n${memoryOccurrence(ledger)}';
    if (item.excerpt) {
      parts.add(
        '$heading$metadata\n${item.text.trim()}\n[Excerpted from a larger Memory Book entry]',
      );
    } else {
      parts.add('$heading$metadata\n${item.text.trim()}');
    }
  }
  return parts.where((part) => part.trim().isNotEmpty).join('\n\n');
}

/// Returns the `start-end` string for [entry.messageRange], or `null` when the
/// entry has no range.
String? formatMemoryRange(MemoryEntry entry) {
  final range = entry.messageRange;
  if (range == null) return null;
  return '${range.start}-${range.end}';
}
