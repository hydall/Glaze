import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/llm/prompt_worker.dart';
import '../../core/llm/tokenizer.dart';
import '../../core/llm/tokenizers/tokenizer_store.dart';
import '../../core/utils/platform_paths.dart';
import 'api_list_provider.dart';

/// The tokenizer the active chat connection asks for, or null while the
/// connection list is still loading.
final requestedTokenizerProvider = Provider<TokenizerKind?>((ref) {
  final config = ref.watch(activeApiConfigProvider);
  if (config == null) return null;
  return resolveTokenizerKind(
    setting: config.tokenizer,
    model: config.model,
    protocol: config.protocol,
  );
});

enum TokenizerPhase { ready, downloading, failed }

@immutable
class TokenizerStatus {
  const TokenizerStatus({
    required this.requested,
    required this.active,
    required this.phase,
  });

  /// What the connection asks for.
  final TokenizerKind requested;

  /// What [estimateTokens] counts with right now. Differs from [requested]
  /// while its vocabulary downloads, or after the download failed.
  final TokenizerKind active;
  final TokenizerPhase phase;

  @override
  bool operator ==(Object other) =>
      other is TokenizerStatus &&
      other.requested == requested &&
      other.active == active &&
      other.phase == phase;

  @override
  int get hashCode => Object.hash(requested, active, phase);
}

final tokenizerStatusProvider =
    NotifierProvider<TokenizerController, TokenizerStatus>(
      TokenizerController.new,
    );

/// Keeps both isolates counting with the tokenizer the active connection
/// wants, downloading it on first use.
class TokenizerController extends Notifier<TokenizerStatus> {
  static const _prefsKey = 'tokenizer_last_active';

  TokenizerStore? _store;
  int _seq = 0;

  @override
  TokenizerStatus build() => TokenizerStatus(
    requested: activeTokenizerKind,
    active: activeTokenizerKind,
    phase: TokenizerPhase.ready,
  );

  Future<TokenizerStore> _getStore() async =>
      _store ??= TokenizerStore(dataDir: await getAppDataDir());

  /// Startup: loads the tokenizer the previous session ended on, from cache
  /// only, so prompts count properly before the connection list has loaded.
  /// Never downloads — [activate] does that once the connection is known.
  Future<void> restore() async {
    final store = await _getStore();
    await store.pruneStale();
    final prefs = await SharedPreferences.getInstance();
    final kind =
        TokenizerKind.fromId(prefs.getString(_prefsKey)) ?? TokenizerKind.o200k;
    if (!await store.isCached(kind)) return;
    if (!await activateTokenizer(kind, store.dataDir)) return;
    _pointWorkerAt(kind);
    state = TokenizerStatus(
      requested: kind,
      active: kind,
      phase: TokenizerPhase.ready,
    );
  }

  /// Switches to [kind]. Until it is ready the previous tokenizer keeps
  /// counting; a newer call supersedes an unfinished one.
  Future<void> activate(TokenizerKind kind) async {
    final seq = ++_seq;
    if (kind == state.active && state.phase == TokenizerPhase.ready) {
      state = TokenizerStatus(
        requested: kind,
        active: kind,
        phase: TokenizerPhase.ready,
      );
      return;
    }
    try {
      final store = await _getStore();
      if (!await store.isCached(kind)) {
        if (seq != _seq) return;
        state = TokenizerStatus(
          requested: kind,
          active: activeTokenizerKind,
          phase: TokenizerPhase.downloading,
        );
        await store.ensureCached(kind);
      }
      if (seq != _seq) return;
      if (!await activateTokenizer(kind, store.dataDir)) {
        if (seq != _seq) return;
        throw StateError('Tokenizer cache for ${kind.id} is unreadable');
      }
      if (seq != _seq) return;
      _pointWorkerAt(kind);
      state = TokenizerStatus(
        requested: kind,
        active: kind,
        phase: TokenizerPhase.ready,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, kind.id);
    } catch (e) {
      debugPrint('[tokenizer] activating ${kind.id} failed: $e');
      if (seq != _seq) return;
      state = TokenizerStatus(
        requested: kind,
        active: activeTokenizerKind,
        phase: TokenizerPhase.failed,
      );
    }
  }

  /// Queues the switch in the prompt worker without waiting for it: requests
  /// sent after this point already count with [kind], and a worker busy with
  /// a long build must not hold the status (or fail it on a timeout).
  void _pointWorkerAt(TokenizerKind kind) {
    unawaited(
      PromptWorker.setTokenizer(kind).catchError((Object e) {
        debugPrint('[tokenizer] prompt worker switch to ${kind.id}: $e');
      }),
    );
  }

  /// Tries the last requested tokenizer again after a failed download.
  Future<void> retry() => activate(state.requested);
}
