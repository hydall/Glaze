import 'package:collection/collection.dart';

import 'memory_book.dart';

/// Operations for the append-only text history of one MemoryBook entry.
class MemoryEntryRevisions {
  const MemoryEntryRevisions._();

  static MemoryEntry initialize(
    MemoryEntry entry, {
    String author = 'system',
    String reason = 'imported_legacy',
    String? reviewer,
  }) {
    if (entry.revisions.isNotEmpty) return entry;
    final initial = snapshot(
      entry,
      id: '${entry.id}:r1',
      version: 1,
      createdAt: entry.createdAt ?? 0,
      author: author,
      reason: reason,
      reviewer: reviewer,
    );
    return entry.copyWith(activeRevisionId: initial.id, revisions: [initial]);
  }

  static MemoryEntryRevision snapshot(
    MemoryEntry entry, {
    required String id,
    required int version,
    required int createdAt,
    required String author,
    required String reason,
    String? reviewer,
  }) => MemoryEntryRevision(
    id: id,
    version: version,
    title: entry.title,
    content: entry.content,
    keys: entry.keys,
    keyParagraphs: entry.keyParagraphs,
    ledgerRange: entry.ledgerRange,
    messageIds: entry.messageIds,
    sourceManifest: entry.sourceManifest,
    createdAt: createdAt,
    author: author,
    reason: reason,
    reviewer: reviewer,
    reviewedAt: reviewer == null ? null : createdAt,
  );

  static bool matchesText(MemoryEntry entry, MemoryEntryRevision revision) =>
      entry.title == revision.title &&
      entry.content == revision.content &&
      entry.ledgerRange == revision.ledgerRange &&
      const ListEquality<String>().equals(entry.keys, revision.keys) &&
      const DeepCollectionEquality().equals(
        entry.keyParagraphs,
        revision.keyParagraphs,
      );

  static void validate(MemoryEntry entry) {
    final revisions = entry.revisions;
    if (revisions.isEmpty ||
        entry.activeRevisionId != revisions.last.id ||
        revisions.map((revision) => revision.id).toSet().length !=
            revisions.length ||
        revisions.asMap().entries.any(
          (item) => item.value.version != item.key + 1,
        ) ||
        !matchesText(entry, revisions.last)) {
      throw StateError('Invalid memory revision history. Reload the memory.');
    }
  }

  /// Legacy in-memory projections remain usable; persisted histories must agree
  /// with their active text before they can participate in retrieval.
  static bool isUsable(MemoryEntry entry) {
    if (entry.revisions.isEmpty) return entry.activeRevisionId == null;
    try {
      validate(entry);
      return true;
    } on StateError {
      return false;
    }
  }

  /// Normalizes a legacy or newly-created entry and appends a snapshot when
  /// its editable projection differs from the durable active revision.
  static MemoryEntry prepare(
    MemoryEntry proposed,
    MemoryEntry? stored, {
    String author = 'system',
    String reason = 'update',
    String? reviewer,
  }) {
    if (stored == null) {
      final initial = initialize(proposed);
      validate(initial);
      return initial;
    }
    final current = initialize(stored);
    validate(current);
    final hadIncomingHistory = proposed.revisions.isNotEmpty;
    final incoming = initialize(proposed);

    if (incoming.revisions.length > current.revisions.length) {
      validate(incoming);
      if (incoming.revisions
          .take(current.revisions.length)
          .toList()
          .asMap()
          .entries
          .any((item) => item.value != current.revisions[item.key])) {
        throw StateError(
          'Memory revision history changed. Reload before saving.',
        );
      }
      if (!matchesText(proposed, incoming.revisions.last)) {
        throw StateError('Invalid memory revision projection.');
      }
      return incoming;
    }
    if (hadIncomingHistory &&
        incoming.revisions.length < current.revisions.length &&
        !matchesText(proposed, current.revisions.last)) {
      throw StateError(
        'Memory revision history changed. Reload before saving.',
      );
    }
    if (hadIncomingHistory &&
        incoming.revisions.length == current.revisions.length &&
        incoming.revisions.asMap().entries.any(
          (item) => item.value != current.revisions[item.key],
        )) {
      throw StateError(
        'Memory revision history changed. Reload before saving.',
      );
    }
    if (matchesText(proposed, current.revisions.last) &&
        reason != 'restore_revision') {
      return proposed.copyWith(
        revisions: current.revisions,
        activeRevisionId: current.activeRevisionId,
      );
    }

    final revision = snapshot(
      proposed,
      id: '${proposed.id}:r${current.revisions.length + 1}',
      version: current.revisions.length + 1,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      author: author,
      reason: reason,
      reviewer: reviewer,
    );
    return proposed.copyWith(
      revisions: [...current.revisions, revision],
      activeRevisionId: revision.id,
    );
  }

  /// Restoration is itself a new revision, so the original edit remains
  /// auditable and the active pointer never moves backwards.
  static MemoryEntry restoreText(
    MemoryEntry current,
    MemoryEntryRevision revision,
  ) => current.copyWith(
    title: revision.title,
    content: revision.content,
    keys: revision.keys,
    keyParagraphs: revision.keyParagraphs,
    ledgerRange: revision.ledgerRange,
  );

  static MemoryEntryRevision? find(MemoryEntry entry, String revisionId) {
    for (final revision in entry.revisions) {
      if (revision.id == revisionId) return revision;
    }
    return null;
  }

  static MemoryEntry restoreRevision(MemoryEntry current, String revisionId) {
    final revision = find(current, revisionId);
    if (revision == null) {
      throw StateError('Memory revision not found. Reload the memory.');
    }
    return restoreText(current, revision);
  }
}
