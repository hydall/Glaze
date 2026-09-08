import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/api_list_provider.dart';
import '../llm/embedding_service.dart';
import '../llm/memory_injection_service.dart';
import '../llm/vector_rebuild_service.dart';
import 'db_provider.dart';
import 'lorebook_embedding_provider.dart';

enum VectorRebuildStatus { idle, running, paused, cancelled, completed, error }

class VectorRebuildState {
  final VectorRebuildStatus status;
  final int current;
  final int total;
  final int indexed;
  final int skipped;
  final int failed;
  final String currentLabel;
  final String message;

  const VectorRebuildState({
    this.status = VectorRebuildStatus.idle,
    this.current = 0,
    this.total = 0,
    this.indexed = 0,
    this.skipped = 0,
    this.failed = 0,
    this.currentLabel = '',
    this.message = '',
  });

  double get progress => total <= 0 ? 0 : current / total;
  bool get isRunning => status == VectorRebuildStatus.running;
  bool get isPaused => status == VectorRebuildStatus.paused;
  bool get canStart => !isRunning && !isPaused;

  VectorRebuildState copyWith({
    VectorRebuildStatus? status,
    int? current,
    int? total,
    int? indexed,
    int? skipped,
    int? failed,
    String? currentLabel,
    String? message,
  }) {
    return VectorRebuildState(
      status: status ?? this.status,
      current: current ?? this.current,
      total: total ?? this.total,
      indexed: indexed ?? this.indexed,
      skipped: skipped ?? this.skipped,
      failed: failed ?? this.failed,
      currentLabel: currentLabel ?? this.currentLabel,
      message: message ?? this.message,
    );
  }
}

final vectorRebuildServiceProvider = Provider<VectorRebuildService>((ref) {
  return VectorRebuildService(
    ref.watch(chatRepoProvider),
    ref.watch(memoryBookRepoProvider),
    ref.watch(lorebookRepoProvider),
    ref.watch(embeddingRepoProvider),
    ref.watch(memoryEmbeddingServiceProvider),
    ref.watch(lorebookEmbeddingServiceProvider),
    ref.watch(chatMessageEmbeddingServiceProvider),
    ref.watch(embeddingConfigProvider),
  );
});

final vectorRebuildControllerProvider =
    NotifierProvider<VectorRebuildController, VectorRebuildState>(
      VectorRebuildController.new,
    );

final embeddingStaleStatsProvider = FutureProvider((ref) async {
  await ref.watch(apiListProvider.future);
  final config = ref.watch(embeddingConfigProvider);
  final signature = embeddingModelSignature(config);
  return ref.watch(embeddingRepoProvider).getStaleStats(signature);
});

class VectorRebuildController extends Notifier<VectorRebuildState> {
  bool _cancelRequested = false;
  Completer<void>? _pauseCompleter;

  @override
  VectorRebuildState build() => const VectorRebuildState();

  Future<void> start(VectorRebuildRequest request) async {
    if (!state.canStart || request.sources.isEmpty) return;

    _cancelRequested = false;
    _pauseCompleter = null;
    state = const VectorRebuildState(
      status: VectorRebuildStatus.running,
      message: 'Preparing vector rebuild...',
    );

    try {
      await ref.read(apiListProvider.future);
      final config = ref.read(embeddingConfigProvider);
      if (config.endpoint.isEmpty) {
        state = state.copyWith(
          status: VectorRebuildStatus.error,
          message: 'Configure an embedding endpoint before rebuilding vectors.',
        );
        return;
      }

      final result = await ref
          .read(vectorRebuildServiceProvider)
          .rebuild(
            request,
            isCancelled: () => _cancelRequested,
            waitIfPaused: _waitIfPaused,
            onPrepared: (total) {
              state = state.copyWith(
                total: total,
                message: total == 0
                    ? 'No vector rebuild work found.'
                    : 'Rebuilding vectors...',
              );
            },
            onTaskStarted: (_, label, sourceLabel) {
              state = state.copyWith(
                status: VectorRebuildStatus.running,
                currentLabel: label,
                message: sourceLabel,
              );
            },
            onTaskCompleted: (current, result) {
              state = state.copyWith(
                current: current,
                indexed: result.indexed,
                skipped: result.skipped,
                failed: result.failed,
              );
            },
          );

      if (result.cancelled) {
        state = state.copyWith(
          status: VectorRebuildStatus.cancelled,
          message: 'Vector rebuild cancelled.',
        );
        return;
      }
      state = state.copyWith(
        status: VectorRebuildStatus.completed,
        currentLabel: '',
        message: result.total == 0
            ? 'No vector rebuild work found.'
            : 'Vector rebuild complete.',
      );
      if (result.total > 0) ref.invalidate(embeddingStaleStatsProvider);
    } catch (e) {
      state = state.copyWith(
        status: VectorRebuildStatus.error,
        message: 'Vector rebuild failed: $e',
      );
    }
  }

  void pause() {
    if (!state.isRunning) return;
    _pauseCompleter ??= Completer<void>();
    state = state.copyWith(
      status: VectorRebuildStatus.paused,
      message: 'Vector rebuild paused.',
    );
  }

  void resume() {
    if (!state.isPaused) return;
    final completer = _pauseCompleter;
    _pauseCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
    state = state.copyWith(
      status: VectorRebuildStatus.running,
      message: 'Rebuilding vectors...',
    );
  }

  void cancel() {
    if (!state.isRunning && !state.isPaused) return;
    _cancelRequested = true;
    resume();
  }

  Future<void> _waitIfPaused() async {
    final completer = _pauseCompleter;
    if (completer != null) await completer.future;
  }
}
