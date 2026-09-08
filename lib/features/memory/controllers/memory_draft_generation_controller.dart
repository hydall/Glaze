import 'dart:async';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/memory_book.dart';
import '../../../core/models/pipeline_settings.dart';
import '../../../core/state/memory_settings_provider.dart';
import '../../../core/state/pipeline_settings_provider.dart';
import '../../chat/chat_provider.dart';
import '../../chat/memory_draft_generator.dart';
import '../state/memory_active_drafts_provider.dart';
import 'memory_settings_mapper.dart';

/// Owns the memory-draft generation lifecycle for a single chat session:
/// the active/generating sets, cancel tokens, and the elapsed-timer. Extracted
/// from [MemoryBookController] (plan §6) so the host controller stays a thin
/// orchestrator for entry/index CRUD + settings mapping.
///
/// INV-M3 (chat vs memory-draft mutual exclusion) is preserved: `generateDraft`
/// refuses to start when `chatProvider(charId).value?.isGenerating == true`
/// and marks the sessionId active on `memoryActiveDraftsProvider` for the
/// duration of the generation (matching the chat-side INV-M4 guard). The mutex
/// contract is characterized by `test/characterization/memory_draft_mutex_test.dart`
/// (which pins the shared provider, not this controller directly).
///
/// The controller does not own the [MemoryBook] — the host does. It reads the
/// book via [bookGetter] and atomically persists updates (book + save) via
/// [persistAndSet], so there is a single owner of `_book` and a single
/// `save()` code path.
class MemoryDraftGenerationController {
  final WidgetRef _ref;
  final String _charId;
  final String _sessionId;
  final MemorySettingsMapper _settingsMapper;

  /// Returns the host's current [MemoryBook] (or `null` if not loaded).
  final MemoryBook? Function() bookGetter;

  /// Atomically sets the host's `_book` to [book] and persists it. The single
  /// write path — keeps `_book` ownership in the host and avoids divergent
  /// save code.
  final Future<void> Function(MemoryBook book) persistAndSet;

  final Map<String, bool> _generatingDrafts = {};
  final Set<String> _activeDraftIds = {};
  final Map<String, DateTime> _genStartTimes = {};
  final Map<String, CancelToken> _cancelTokens = {};
  Timer? _genElapsedTimer;

  MemoryDraftGenerationController({
    required this._ref,
    required this._charId,
    required this._sessionId,
    required this._settingsMapper,
    required this.bookGetter,
    required this.persistAndSet,
  });
  Map<String, bool> get generatingDrafts => Map.unmodifiable(_generatingDrafts);
  Map<String, DateTime> get genStartTimes => Map.unmodifiable(_genStartTimes);

  /// The global memory settings (singleton, SharedPreferences-backed).
  MemoryGlobalSettings get _globalSettings =>
      _ref.read(memoryGlobalSettingsProvider);
  PipelineSettings get _pipelineSettings =>
      _ref.read(pipelineSettingsProvider);

  MemoryBookSettings get _bookSettings =>
      _settingsMapper.globalToBook(_globalSettings);
  PipelineSettings get _pipeline => _pipelineSettings;

  void generateAllPending() {
    final book = bookGetter();
    if (book == null) return;
    final needsGen = book.pendingDrafts
        .where(
          (d) =>
              d.content.isEmpty &&
              (d.status == 'pending_generation' ||
                  d.status == 'needs_regeneration') &&
              !_activeDraftIds.contains(d.id),
        )
        .toList();

    for (final draft in needsGen) {
      generateDraft(
        draft.id,
        onStart: () {},
        onComplete: () {},
        onError: (e) {},
      );
    }
  }

  /// Generates a draft. Callbacks are for UI updates.
  Future<void> generateDraft(
    String draftId, {
    required void Function() onStart,
    required void Function() onComplete,
    required void Function(String error) onError,
  }) async {
    final book = bookGetter();
    if (book == null || _activeDraftIds.contains(draftId)) return;
    final chatState = _ref.read(chatProvider(_charId));
    if (chatState.value?.isGenerating == true) {
      onError('memory_books_chat_generation_active'.tr());
      return;
    }
    final draftIndex = book.pendingDrafts.indexWhere((d) => d.id == draftId);
    if (draftIndex < 0) return;

    final session = chatState.value?.session;
    if (session == null) return;

    final draft = book.pendingDrafts[draftIndex];
    final draftMessages = session.messages
        .where((m) => draft.messageIds.contains(m.id))
        .toList();
    if (draftMessages.isEmpty) {
      onError('memory_books_messages_not_found'.tr());
      return;
    }

    final historyText = draftMessages
        .map((m) => '${m.role}: ${m.content}')
        .join('\n\n');
    final cancelToken = CancelToken();
    _cancelTokens[draftId] = cancelToken;

    _activeDraftIds.add(draftId);
    _generatingDrafts[draftId] = true;
    _genStartTimes[draftId] = DateTime.now();
    _startGenElapsedTimer();
    _ref.read(memoryActiveDraftsProvider.notifier).markActive(_sessionId);
    onStart();

    try {
      final generator = MemoryDraftGenerator(_ref);
      final result = await generator.generate(
        draft: draft,
        settings: _bookSettings,
        pipeline: _pipeline,
        historyText: historyText,
        cancelToken: cancelToken,
      );

      final currentBook = bookGetter();
      if (currentBook == null) return;
      final updatedDrafts = [...currentBook.pendingDrafts];
      updatedDrafts[draftIndex] = result;
      await persistAndSet(currentBook.copyWith(pendingDrafts: updatedDrafts));
      _activeDraftIds.remove(draftId);
      _generatingDrafts.remove(draftId);
      _genStartTimes.remove(draftId);
      _stopGenElapsedTimer();
      if (_generatingDrafts.isEmpty) {
        _ref.read(memoryActiveDraftsProvider.notifier).markInactive(_sessionId);
      }
      onComplete();
    } catch (e) {
      final currentBook = bookGetter();
      if (currentBook == null) return;
      final updatedDrafts = [...currentBook.pendingDrafts];
      updatedDrafts[draftIndex] = updatedDrafts[draftIndex].copyWith(
        status: 'needs_regeneration',
        error: e.toString(),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      await persistAndSet(currentBook.copyWith(pendingDrafts: updatedDrafts));
      _activeDraftIds.remove(draftId);
      _generatingDrafts.remove(draftId);
      _genStartTimes.remove(draftId);
      _stopGenElapsedTimer();
      if (_generatingDrafts.isEmpty) {
        _ref.read(memoryActiveDraftsProvider.notifier).markInactive(_sessionId);
      }
      onError(e.toString());
    } finally {
      _cancelTokens.remove(draftId);
    }
  }

  void cancelDraftGeneration(String draftId) {
    _cancelTokens[draftId]?.cancel();
    _activeDraftIds.remove(draftId);
    _generatingDrafts.remove(draftId);
    if (_generatingDrafts.isEmpty) {
      _ref.read(memoryActiveDraftsProvider.notifier).markInactive(_sessionId);
    }
  }

  Future<void> batchGenerate({
    required void Function() onStart,
    required void Function() onComplete,
    required void Function(String error) onError,
  }) async {
    final book = bookGetter();
    if (book == null) return;
    final needsGen = book.pendingDrafts
        .where(
          (d) =>
              d.content.isEmpty &&
              (d.status == 'pending_generation' ||
                  d.status == 'needs_regeneration') &&
              !_activeDraftIds.contains(d.id),
        )
        .toList();
    final batchSize = _globalSettings.batchSize;
    final toGenerate = needsGen.take(batchSize).toList();
    if (toGenerate.isEmpty) return;

    // Stagger starts so LLM requests don't all fire at once.
    final futures = <Future<void>>[];
    for (var i = 0; i < toGenerate.length; i++) {
      if (i > 0) await Future<void>.delayed(const Duration(seconds: 2));
      futures.add(
        generateDraft(
          toGenerate[i].id,
          onStart: onStart,
          onComplete: () {},
          onError: onError,
        ),
      );
    }
    await Future.wait(futures);
    onComplete();
  }

  List<MemoryDraft> get draftsNeedingGeneration {
    final book = bookGetter();
    if (book == null) return [];
    return book.pendingDrafts
        .where(
          (d) =>
              d.content.isEmpty &&
              (d.status == 'pending_generation' ||
                  d.status == 'needs_regeneration') &&
              !_activeDraftIds.contains(d.id),
        )
        .toList();
  }

  bool get isGenerating => _generatingDrafts.values.any((v) => v);

  void _startGenElapsedTimer() {
    _genElapsedTimer ??= Timer.periodic(
      const Duration(milliseconds: 200),
      (_) {},
    );
  }

  void _stopGenElapsedTimer() {
    if (_generatingDrafts.isEmpty) {
      _genElapsedTimer?.cancel();
      _genElapsedTimer = null;
    }
  }

  void dispose() {
    _genElapsedTimer?.cancel();
  }
}
