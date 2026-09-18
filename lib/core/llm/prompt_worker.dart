import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import '../utils/platform_paths.dart';

import '../models/chat_message.dart';
import '../models/memory_entry_revisions.dart';
import '../utils/cast_helpers.dart';
import 'glaze_matcher.dart';
import 'memory_budget.dart';
import 'memory_retrieval_mode.dart';
import 'memory_selector.dart';
import 'prompt_builder.dart';
import 'prompt_inputs.dart';
import 'prompt_worker_codec.dart';
import 'tokenizer.dart';

enum PromptWorkerPriority { foreground, background }

/// Human-readable size of a serialized worker payload.
String _payloadSize(int bytes) {
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
  return '${(kb / 1024).toStringAsFixed(1)} MB';
}

/// What a worker request was, in terms a reader can act on.
///
/// The timeout used to name only the deadline it missed, which is why both
/// reports of it are unanswerable: "Glaze throws a TimeoutException for
/// PromptWorker (request timed out after 60000ms) when using a char imported
/// with ST backup" says nothing about how big that chat was, and neither does
/// "PromptWorker getting overwhelmed with too many lorebooks/regexes". The
/// serialized payload carries the history, the lorebooks and the regex
/// scripts, so its size is the one number that separates "an enormous chat"
/// from "something is stuck".
String describeWorkerRequest(String command, Object? data) {
  if (data is! String) return command;
  return '$command, ${_payloadSize(data.length)} payload';
}

/// The deadline for a request of [payloadBytes].
///
/// A flat 60 s is not a statement about the work; it is a statement about how
/// long Glaze is willing to wait for an isolate it cannot interrupt. But a
/// prompt build scales with the chat it is building from, and a SillyTavern
/// import arrives with chats far larger than anything Glaze creates itself —
/// against a fixed cap, such a character never generates at all, which is the
/// report. So the budget grows with the payload and stops growing at
/// [maxRequestTimeout]: a genuinely stuck isolate is still detected and
/// replaced, just later.
Duration timeoutForPayload(int payloadBytes, {Duration? base, Duration? cap}) {
  final floor = base ?? PromptWorker.requestTimeout;
  final ceiling = cap ?? PromptWorker.maxRequestTimeout;
  if (ceiling <= floor) return floor;
  final megabytes = payloadBytes / (1024 * 1024);
  final scaled = floor + Duration(milliseconds: (megabytes * 15000).round());
  return scaled > ceiling ? ceiling : scaled;
}

/// Long-lived isolate worker that runs buildPrompt off the main thread.
///
/// The isolate loads its own o200k_base tokenizer once at startup and
/// maintains a persistent token cache across requests.
class PromptWorker {
  /// Overridden by queue timeout tests.
  static Duration requestTimeout = const Duration(seconds: 60);

  /// The most [timeoutForPayload] will allow, however large the payload.
  static Duration maxRequestTimeout = const Duration(seconds: 180);

  static PromptWorker? _instance;
  static Completer<PromptWorker>? _initGuard;

  Isolate? _isolate;
  ReceivePort? _commandPort;
  ReceivePort? _responsePort;
  StreamSubscription<dynamic>? _responseSubscription;
  SendPort? _sendPort;
  final List<_PromptWorkerRequest> _queue = [];
  _PromptWorkerRequest? _active;
  Timer? _activeTimer;
  bool _restarting = false;
  bool _disposed = false;
  int _requestId = 0;

  PromptWorker._();

  static Future<PromptWorker> ensureInitialized() async {
    if (_instance != null) return _instance!;
    // Serialize concurrent first-init / respawn attempts.
    if (_initGuard != null) return _initGuard!.future;
    _initGuard = Completer<PromptWorker>();
    try {
      _instance = await _create();
      _initGuard!.complete(_instance!);
    } catch (e, st) {
      _initGuard!.completeError(e, st);
      _initGuard = null;
      rethrow;
    }
    _initGuard = null;
    return _instance!;
  }

  static Future<PromptWorker> _create() async {
    final worker = PromptWorker._();
    await worker._spawnIsolate();
    await worker._send('init', null);
    return worker;
  }

  Future<void> _spawnIsolate() async {
    final appSupportPath = await getAppDataDir();

    final commandPort = ReceivePort();
    final responsePort = ReceivePort();

    final isolate = await Isolate.spawn(_isolateEntryPoint, [
      commandPort.sendPort,
      responsePort.sendPort,
      appSupportPath,
    ]);

    final sendPort = await commandPort.first as SendPort;
    _isolate = isolate;
    _commandPort = commandPort;
    _responsePort = responsePort;
    _sendPort = sendPort;
    _responseSubscription = responsePort.listen((message) {
      if (message is List && message.length == 2) {
        final id = message[0] as int;
        final data = message[1];
        _handleResponse(id, data);
      }
    });
  }

  Future<dynamic> _send(
    String command,
    dynamic data, {
    bool addFirst = false,
    PromptWorkerPriority priority = PromptWorkerPriority.foreground,
    Duration? timeout,
  }) {
    if (_disposed) {
      return Future<dynamic>.error(StateError('PromptWorker is disposed'));
    }
    final completer = Completer<dynamic>();
    final request = _PromptWorkerRequest(
      id: _requestId++,
      command: command,
      data: data,
      completer: completer,
      priority: priority,
      timeout: timeout ?? requestTimeout,
    );
    if (addFirst) {
      _queue.insert(0, request);
    } else if (priority == PromptWorkerPriority.foreground) {
      final firstBackground = _queue.indexWhere(
        (queued) => queued.priority == PromptWorkerPriority.background,
      );
      _queue.insert(
        firstBackground < 0 ? _queue.length : firstBackground,
        request,
      );
    } else {
      _queue.add(request);
    }
    _dispatchNext();
    return completer.future;
  }

  void _dispatchNext() {
    if (_disposed || _restarting || _active != null || _queue.isEmpty) return;
    final sendPort = _sendPort;
    if (sendPort == null) return;

    final request = _queue.removeAt(0);
    _active = request;
    // Only the request actually executing in the isolate owns a timeout.
    // Queued requests do not lose their budget while waiting for earlier work.
    _activeTimer = Timer(request.timeout, () {
      if (!identical(_active, request)) return;
      _active = null;
      if (!request.completer.isCompleted) {
        request.completer.completeError(
          TimeoutException(
            'PromptWorker request timed out after '
            '${request.timeout.inMilliseconds}ms '
            '(${describeWorkerRequest(request.command, request.data)})',
            request.timeout,
          ),
        );
      }
      // Synchronous regex/ReDoS cannot be interrupted. Replace the isolate,
      // but retain requests which have not been dispatched yet.
      unawaited(_restartAfterTimeout());
    });
    sendPort.send([request.id, request.command, request.data]);
  }

  void _handleResponse(int id, dynamic data) {
    final request = _active;
    if (request == null || request.id != id) return;
    _activeTimer?.cancel();
    _activeTimer = null;
    _active = null;
    if (!request.completer.isCompleted) {
      if (data is Map && data.containsKey('error')) {
        request.completer.completeError(Exception(data['error'] as String));
      } else {
        request.completer.complete(data);
      }
    }
    _dispatchNext();
  }

  Future<void> _restartAfterTimeout() async {
    if (_restarting || _disposed) return;
    _restarting = true;
    _closeIsolate();
    try {
      await _spawnIsolate();
      _restarting = false;
      // Preloading must complete before retained requests are dispatched.
      await _send(
        'init',
        null,
        addFirst: true,
        timeout: const Duration(seconds: 60),
      );
    } catch (error, stackTrace) {
      _restarting = false;
      _failQueued(error, stackTrace);
      if (_instance == this) _instance = null;
    }
  }

  void _closeIsolate() {
    _activeTimer?.cancel();
    _activeTimer = null;
    unawaited(_responseSubscription?.cancel());
    _responseSubscription = null;
    _commandPort?.close();
    _responsePort?.close();
    _isolate?.kill(priority: Isolate.immediate);
    _commandPort = null;
    _responsePort = null;
    _isolate = null;
    _sendPort = null;
  }

  void _failQueued(Object error, StackTrace stackTrace) {
    for (final request in _queue) {
      if (!request.completer.isCompleted) {
        request.completer.completeError(error, stackTrace);
      }
    }
    _queue.clear();
  }

  Future<PromptResult> buildPrompt(
    PromptPayload payload, {
    PromptWorkerPriority priority = PromptWorkerPriority.foreground,
  }) async {
    final json = jsonEncode(serializePayload(payload));
    final response =
        await _send(
              'buildPrompt',
              json,
              priority: priority,
              timeout: timeoutForPayload(json.length),
            )
            as String;
    return deserializeResult(jsonDecode(response) as Map<String, dynamic>);
  }

  /// Builds a complete prompt from raw inputs. This runs memory injection,
  /// lorebook scanning, prompt assembly, and tokenization all in the isolate.
  Future<PromptResult> buildFromInputs(
    PromptInputs inputs, {
    PromptWorkerPriority priority = PromptWorkerPriority.background,
  }) async {
    final json = jsonEncode(inputs.toJson());
    final response =
        await _send(
              'buildFromInputs',
              json,
              priority: priority,
              timeout: timeoutForPayload(json.length),
            )
            as String;
    return deserializeResult(jsonDecode(response) as Map<String, dynamic>);
  }

  /// Test-only command used to exercise queueing and restart semantics.
  Future<String> debugBlock(
    Duration duration,
    String result, {
    PromptWorkerPriority priority = PromptWorkerPriority.background,
  }) async {
    return await _send('debugBlock', {
          'milliseconds': duration.inMilliseconds,
          'result': result,
        }, priority: priority)
        as String;
  }

  void dispose() {
    _disposed = true;
    _closeIsolate();
    final error = StateError('PromptWorker disposed with pending requests');
    final active = _active;
    _active = null;
    if (active != null && !active.completer.isCompleted) {
      active.completer.completeError(error);
    }
    _failQueued(error, StackTrace.current);
    if (_instance == this) _instance = null;
  }
}

class _PromptWorkerRequest {
  const _PromptWorkerRequest({
    required this.id,
    required this.command,
    required this.data,
    required this.completer,
    required this.priority,
    required this.timeout,
  });

  final int id;
  final String command;
  final dynamic data;
  final Completer<dynamic> completer;
  final PromptWorkerPriority priority;
  final Duration timeout;
}

void _isolateEntryPoint(List<dynamic> args) {
  final commandSendPort = args[0] as SendPort;
  final responseSendPort = args[1] as SendPort;
  final appSupportPath = args[2] as String;

  final commandPort = ReceivePort();
  commandSendPort.send(commandPort.sendPort);

  commandPort.listen((message) async {
    if (message is! List || message.length != 3) return;

    final id = message[0] as int;
    final command = message[1] as String;
    final data = message[2];

    try {
      switch (command) {
        case 'init':
          await preloadO200kBaseInIsolate(appSupportPath);
          responseSendPort.send([id, 'ok']);

        case 'buildPrompt':
          final payload = deserializePayload(
            jsonDecode(data as String) as Map<String, dynamic>,
          );
          final result = buildPrompt(payload);
          responseSendPort.send([id, jsonEncode(serializeResult(result))]);

        case 'buildFromInputs':
          final inputs = PromptInputs.fromJson(
            jsonDecode(data as String) as Map<String, dynamic>,
          );
          final result2 = _buildFromInputs(inputs);
          responseSendPort.send([id, jsonEncode(serializeResult(result2))]);

        case 'debugBlock':
          final options = data as Map;
          final duration = Duration(
            milliseconds: options['milliseconds'] as int,
          );
          final watch = Stopwatch()..start();
          while (watch.elapsed < duration) {}
          responseSendPort.send([id, options['result'] as String]);

        default:
          responseSendPort.send([
            id,
            {'error': 'Unknown command: $command'},
          ]);
      }
    } catch (e, st) {
      responseSendPort.send([
        id,
        {'error': '$e\n$st'},
      ]);
    }
  });
}

/// Builds a complete prompt from raw inputs in the isolate.
PromptResult _buildFromInputs(PromptInputs inputs) {
  // 1. Memory injection (no vector search in isolate)
  String? memoryContent;
  String? memoryMacroContent;
  String memoryInjectionTarget = inputs.memoryInjectionTarget;
  List<TriggeredEntry> triggeredMemories = [];
  MemorySelection? memorySelection;

  if (inputs.memoryEnabled && inputs.memoryEntries.isNotEmpty) {
    final validEntries = inputs.memoryEntries
        .where(
          (entry) =>
              MemoryEntryRevisions.isUsable(entry) &&
              entry.sourceManifest?.invalidated != true,
        )
        .toList();
    final visibleHistory = inputs.history
        .where((m) => !m.isHidden && !m.isTyping)
        .toList();
    final scanText = visibleHistory
        .map((m) => m.content)
        .join('\n')
        .toLowerCase();
    final keywordMatched = <String, List<String>>{};
    for (final entry in validEntries) {
      if (entry.status != 'active' || entry.content.trim().isEmpty) continue;
      final matched = <String>{};
      for (final key in entry.keys) {
        if (key.isEmpty) continue;
        final lowerKey = key.toLowerCase();
        if (inputs.memoryKeyMatchMode == 'glaze') {
          if (_glazeMatch(lowerKey, scanText)) matched.add(key);
        } else if (inputs.memoryKeyMatchMode == 'both') {
          if (scanText.contains(lowerKey) || _glazeMatch(lowerKey, scanText)) {
            matched.add(key);
          }
        } else {
          if (scanText.contains(lowerKey)) matched.add(key);
        }
      }
      if (matched.isNotEmpty) keywordMatched[entry.id] = matched.toList();
    }

    final retrievalMode = MemoryRetrievalMode.fromValue(inputs.memoryMode);
    final budget = MemoryInjectionBudget.composeBudget(
      contextBudgetTokens: inputs.memoryContextBudgetTokens > 0
          ? inputs.memoryContextBudgetTokens
          : null,
      percent: inputs.memoryMaxInjectionBudgetPercent,
      absoluteCap: retrievalMode.isLegacy
          ? null
          : inputs.memoryMaxInjectedTokens,
    );

    memorySelection = MemorySelector.select(
      MemorySelectionInput(
        selectionMode: retrievalMode.isLegacy ? 'legacy' : 'v2',
        entries: validEntries,
        keywordMatchedTerms: keywordMatched,
        maxInjectionTokens: budget,
        maxInjectedEntries: inputs.memoryMaxInjected,
        diversityAware: inputs.memoryDiversityAware,
        diversityPenalty: inputs.memoryDiversityPenalty,
        recencyBoost: inputs.memoryRecencyBoost,
        recencyHalfLifeDays: inputs.memoryRecencyHalfLifeDays,
        importanceBoost: inputs.memoryImportanceBoost,
        importanceWeight: inputs.memoryImportanceWeight,
        sourceWindowExclusion: inputs.memorySourceWindowExclusion,
        currentMessageIndex: inputs.history.length,
        chunkBudgeting: inputs.memoryPackingMode == 'chunk_first',
      ),
    );
    final resolved = const MemoryContextResolver().resolve(
      selection: memorySelection,
      visibleMessageIds: const {},
      disableSourceWindowExclusion: false,
      excerptingEnabled: inputs.memoryExcerptingEnabled,
      packingMode: inputs.memoryPackingMode,
      excerptTokensPerChunk: inputs.memoryExcerptTokensPerChunk,
      excerptChunksPerEntry: inputs.memoryExcerptChunksPerEntry,
      chunkFirstTopEntries: inputs.chunkFirstTopEntries,
      chunkFirstTopChunks: inputs.chunkFirstTopChunks,
      summaryExcerpt: inputs.summaryContent,
    );
    final excerptSelection = resolved.excerptSelection;

    final topEntries = excerptSelection.entries;

    if (excerptSelection.items.isNotEmpty) {
      memoryContent = resolved.content!.hardBlockContent;
      memoryMacroContent = resolved.content!.macroContent;
      triggeredMemories = topEntries
          .map(
            (e) => TriggeredEntry(
              id: e.id,
              name: e.title.isNotEmpty ? e.title : e.id,
              source: 'memory',
            ),
          )
          .toList();
    }
  }

  // NEW (patch #4 follow-up): chatSummaryFingerprint analog for prompt
  // cache invalidation. djb2-style hash of the compiled memory injection
  // content so the next generation can detect "memory changed since last
  // turn" and invalidate prompt cache (Anthropic/DeepSeek). The fingerprint
  // is stored on the produced ChatMessage so the NEXT turn can compare.
  // Marinara uses djb2 on the compiled chat summary; we hash the memory
  // injection content (MemoryBook is our summary equivalent — Glaze
  // has no separate Chat Summary system, so MemoryBook IS the summary, and
  // its djb2 fingerprint detects "memory changed since last turn" for
  // prompt-cache invalidation).
  final memoryInjectionFingerprint =
      memoryContent != null && memoryContent.isNotEmpty
      ? computeHash(memoryContent)
      : '';

  // 2. Build payload
  final payload = PromptPayload(
    character: inputs.character,
    persona: inputs.persona,
    preset: inputs.preset,
    history: inputs.history,
    sessionId: inputs.sessionId,
    apiConfig: inputs.apiConfig,
    sessionVars: inputs.sessionVars,
    globalVars: inputs.globalVars,
    summaryContent: inputs.summaryContent,
    guidanceText: inputs.guidanceText,
    lorebooks: inputs.lorebooks,
    lorebookSettings: inputs.lorebookSettings,
    lorebookActivations: inputs.lorebookActivations,
    vectorEntries: inputs.vectorEntries,
    authorsNote: inputs.authorsNote,
    characterDepthPrompt: inputs.characterDepthPrompt,
    characterDepthPromptDepth: inputs.characterDepthPromptDepth,
    characterDepthPromptRole: inputs.characterDepthPromptRole,
    globalRegexes: inputs.globalRegexes,
    memoryContent: memoryContent,
    memoryMacroContent: memoryMacroContent,
    memoryInjectionTarget: memoryInjectionTarget,
    memoryInjectionFingerprint: memoryInjectionFingerprint,
    memoryCoverage: memorySelection == null
        ? const {}
        : {
            'entryIds': memorySelection.entries
                .map((entry) => entry.id)
                .toList(growable: false),
            'needsRebuild': false,
            'stale': false,
            'injected': false,
            'candidatesTotal': memorySelection.allScores.length,
            'excludedBySourceWindow': memorySelection.excludedBySourceWindow,
            'budgetTokens': memorySelection.budgetTokens,
            'budgetTrimmed': memorySelection.budgetTrimmed,
            'packingMode': inputs.memoryPackingMode,
            'excerptTokensPerChunk': inputs.memoryExcerptTokensPerChunk,
            'excerptChunksPerEntry': inputs.memoryExcerptChunksPerEntry,
            'chunkFirstTopEntries': inputs.chunkFirstTopEntries,
            'chunkFirstTopChunks': inputs.chunkFirstTopChunks,
          },
    triggeredMemories: triggeredMemories,
    runtimePromptBlocks: inputs.runtimePromptBlocks,
    memorySelection: memorySelection,
    memoryExcerptingEnabled: inputs.memoryExcerptingEnabled,
    memoryPackingMode: inputs.memoryPackingMode,
    memoryExcerptTokensPerChunk: inputs.memoryExcerptTokensPerChunk,
    memoryExcerptChunksPerEntry: inputs.memoryExcerptChunksPerEntry,
    chunkFirstTopEntries: inputs.chunkFirstTopEntries,
    chunkFirstTopChunks: inputs.chunkFirstTopChunks,
    effectiveCanonProjection: inputs.effectiveCanonProjection,
    effectiveCanonRevisionNumber:
        inputs.effectiveCanonProjection?.revisionNumber,
    effectiveCanonRevisionHash: inputs.effectiveCanonProjection?.revisionHash,
    effectiveCanonCacheIdentity:
        inputs.effectiveCanonProjection?.cacheIdentity ?? '',
    // Raw-input isolate history has not been token-trimmed yet. The final
    // buildPrompt coordinator materializes these channels from the projection.
    characterKnowledgeContent: null,
    studioSessionStateContent: null,
    arcContent: null,
    ledgerPromptInjectionPolicy: inputs.ledgerPromptInjectionPolicy,
    ledgerInjectionCacheIdentity: inputs.ledgerInjectionCacheIdentity,
    ledgerProjectionFreshnessProvenCurrent:
        inputs.ledgerProjectionFreshnessProvenCurrent,
  );

  // 3. Build prompt (lorebook scanning happens inside buildPrompt)
  return buildPrompt(payload);
}

bool _glazeMatch(String key, String text) {
  return glazeCheckMatch(key, text, false, WholeWordMode.glaze);
}
