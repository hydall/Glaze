import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/api_list_provider.dart';
import '../llm/lorebook_embedding_text.dart';
import 'db_provider.dart';
import 'lorebook_embedding_provider.dart';
import 'lorebook_provider.dart';

/// Background indexer behind the global "Auto-index vectors" switch.
///
/// State is the set of lorebook ids queued or being indexed, so an open editor
/// can show the work in flight and reload its per-entry statuses once its book
/// leaves the set.
final lorebookAutoIndexerProvider =
    NotifierProvider<LorebookAutoIndexer, Set<String>>(LorebookAutoIndexer.new);

class LorebookAutoIndexer extends Notifier<Set<String>> {
  /// The editor saves on every keystroke pause; waiting this long after the
  /// last save keeps a typing session from turning into a request per word.
  static const _debounce = Duration(seconds: 2);

  final Map<String, Timer> _timers = {};
  final List<String> _queue = [];
  bool _draining = false;

  @override
  Set<String> build() {
    ref.onDispose(() {
      for (final timer in _timers.values) {
        timer.cancel();
      }
      _timers.clear();
    });
    return const {};
  }

  /// Settings first: with the switch off (the default) nothing else is read,
  /// so callers on the save path pay nothing for it.
  bool get _enabled {
    final settings = ref.read(lorebookSettingsProvider);
    return settings.autoIndexVectors &&
        settings.searchType != 'keyword' &&
        ref.read(vectorSearchAvailableProvider);
  }

  /// Indexes [lorebookId] shortly after its last save.
  void schedule(String lorebookId) {
    if (!_enabled) return;
    _timers.remove(lorebookId)?.cancel();
    _timers[lorebookId] = Timer(_debounce, () {
      _timers.remove(lorebookId);
      _enqueue(lorebookId);
    });
  }

  /// Indexes every lorebook — run when auto-indexing is switched on, so books
  /// saved before that do not wait for their next edit.
  Future<void> scheduleAll() async {
    if (!_enabled) return;
    final books = await ref.read(lorebookRepoProvider).getAll();
    if (!ref.mounted) return;
    for (final book in books) {
      _enqueue(book.id);
    }
  }

  void _enqueue(String lorebookId) {
    if (!_queue.contains(lorebookId)) _queue.add(lorebookId);
    state = {...state, lorebookId};
    unawaited(_drain());
  }

  /// One book at a time: the embedding endpoint is rate limited, and parallel
  /// runs would only trip it sooner.
  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty && ref.mounted) {
        final id = _queue.removeAt(0);
        try {
          await _index(id);
        } catch (e) {
          debugPrint('[lorebook_auto_index] $id failed: $e');
        }
        if (!ref.mounted) return;
        // A save that landed mid-run queued the book again; it stays listed
        // until that pass is done too.
        if (!_queue.contains(id)) state = {...state}..remove(id);
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _index(String lorebookId) async {
    if (!_enabled) return;
    await ref.read(apiListProvider.future);
    if (!ref.mounted) return;
    final config = ref.read(embeddingConfigProvider);
    if (config.endpoint.isEmpty) return;
    final book = await ref.read(lorebookRepoProvider).getById(lorebookId);
    if (book == null || !ref.mounted) return;
    // Entries whose stored fingerprint still matches are skipped inside, so a
    // re-run over an unchanged book costs reads, not requests.
    await ref
        .read(lorebookEmbeddingServiceProvider)
        .indexLorebookEntries(
          book.id,
          book.entries,
          config,
          embeddingTarget:
              book.settings?.embeddingTarget ?? LorebookEmbeddingTarget.content,
          vectorizeAll: book.settings?.vectorizeAllEntries ?? false,
        );
  }
}
