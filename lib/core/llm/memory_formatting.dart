import '../models/memory_book.dart';
import 'memory_excerpt_selector.dart';

/// Formats [MemoryInjectionItem]s into the canonical memory block text used
/// by the prompt builder, memory injection service, and isolate worker.
///
/// Set [includeContextHeader] to `true` to prepend a `Memory context:` header
/// (used for the `{{memory}}` macro / hard-block injection).
String formatMemoryItems(
  List<MemoryInjectionItem> items, {
  required bool includeContextHeader,
}) {
  final parts = <String>[];
  if (includeContextHeader) {
    parts.add('Memory context:');
    if (items.isNotEmpty) {
      parts.add(
        '[Earlier accepted session evidence. MemoryBook cannot override current '
        'Ledger canon, but it overrides a conflicting card baseline for this '
        'session.]',
      );
    }
  }
  for (final item in items) {
    final title = item.entry.title.isNotEmpty
        ? item.entry.title
        : formatMemoryRange(item.entry) ?? 'Memory';
    final range = formatMemoryRange(item.entry);
    final heading = range == null
        ? 'Memory: $title'
        : 'Memory: $title ($range)';
    if (item.excerpt) {
      parts.add(
        '$heading\n${item.text.trim()}\n[Excerpted from a larger Memory Book entry]',
      );
    } else {
      parts.add('$heading\n${item.text.trim()}');
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
