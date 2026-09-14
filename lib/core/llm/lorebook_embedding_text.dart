import '../models/lorebook.dart';

/// Which of a lorebook entry's fields is embedded when the book is indexed.
///
/// SillyTavern's vector storage extension only ever embeds the entry body —
/// `activateWorldInfo` inserts `{ text: x.content }` and skips entries whose
/// content is empty — so [content] is the default here and keeps parity with
/// it. The other targets are Glaze additions for books that carry the
/// searchable wording in the title or in the keys rather than in the body.
abstract final class LorebookEmbeddingTarget {
  /// The entry body. SillyTavern's only behaviour, and the default.
  static const content = 'content';

  /// The entry title (`comment` in the SillyTavern V2 format).
  static const comment = 'comment';

  /// The primary keys, joined — semantic matching against the same words the
  /// keyword scan matches literally.
  static const keys = 'keys';

  /// Title and body together.
  static const both = 'both';

  static const values = <String>[content, comment, keys, both];
}

/// The text that represents [entry] in the embedding index.
///
/// Every caller has to build this the same way: the indexer stores a hash of
/// it, and the search recomputes that hash to decide whether the stored vector
/// still describes the entry. A second, slightly different implementation
/// makes the hashes disagree and the entry drops out of the vector pass
/// without any error to show for it.
///
/// An unknown target falls back to the body, and so does a target whose field
/// is empty on this particular entry: a book-wide setting must not make an
/// entry unindexable just because it has no title or no keys.
String lorebookEmbeddingText(LorebookEntry entry, String? target) {
  final text = switch (target) {
    LorebookEmbeddingTarget.comment => entry.comment,
    LorebookEmbeddingTarget.keys => entry.keys.join(', '),
    LorebookEmbeddingTarget.both => _joinNonEmpty([
      entry.comment,
      entry.content,
    ]),
    _ => entry.content,
  };
  return text.trim().isEmpty ? entry.content : text;
}

String _joinNonEmpty(List<String> parts) =>
    parts.where((part) => part.trim().isNotEmpty).join('\n');

/// The embedding pool an entry belongs to.
enum LorebookVectorPool {
  /// Not embedded at all.
  none,

  /// Searched with the book's own threshold and top-K.
  main,

  /// Keyless entries, searched with the lower `fallbackThreshold` and the
  /// smaller `fallbackTopK` so they cannot flood the prompt.
  fallback,
}

/// Which pool [entry] belongs to.
///
/// Shared by the indexer, the search and the session-overlay worker so the
/// three cannot disagree about what is in the index — an entry the search
/// expects a vector for but the indexer never embedded is a silent miss.
///
/// [vectorizeAll] is the book's opt-in to embedding every entry regardless of
/// its own vector-search flag (SillyTavern's `enabled_for_all`). Under it the
/// keyless pool collapses into the main one, as it does in SillyTavern, where
/// every vectorized entry is queried against the same threshold.
LorebookVectorPool lorebookVectorPoolFor(
  LorebookEntry entry, {
  bool vectorizeAll = false,
}) {
  if (!entry.enabled || entry.constant || entry.excludeFromVectorization) {
    return LorebookVectorPool.none;
  }
  if (entry.vectorSearch || vectorizeAll) return LorebookVectorPool.main;
  if (entry.keys.isEmpty && entry.secondaryKeys.isEmpty) {
    return LorebookVectorPool.fallback;
  }
  return LorebookVectorPool.none;
}

/// Whether [entry] is embedded at all, in either pool.
bool isLorebookEntryIndexable(
  LorebookEntry entry, {
  bool vectorizeAll = false,
}) =>
    lorebookVectorPoolFor(entry, vectorizeAll: vectorizeAll) !=
    LorebookVectorPool.none;
