import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import '../utils/platform_paths.dart';

import '../models/chat_message.dart';
import '../utils/cast_helpers.dart';
import 'glaze_matcher.dart';
import 'memory_budget.dart';
import 'memory_excerpt_selector.dart';
import 'memory_formatting.dart';
import 'memory_selector.dart';
import 'prompt_builder.dart';
import 'prompt_inputs.dart';
import 'prompt_worker_codec.dart';
import 'tokenizer.dart';

/// Long-lived isolate worker that runs buildPrompt off the main thread.
///
/// The isolate loads its own o200k_base tokenizer once at startup and
/// maintains a persistent token cache across requests.
class PromptWorker {
  static PromptWorker? _instance;
  static Completer<PromptWorker>? _initGuard;

  final Isolate _isolate;
  final ReceivePort _commandPort;
  final ReceivePort _responsePort;
  final SendPort _sendPort;
  final Map<int, Completer<dynamic>> _pending = {};
  int _requestId = 0;

  PromptWorker._(
    this._isolate,
    this._commandPort,
    this._responsePort,
    this._sendPort,
  );

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
    final appSupportPath = await getAppDataDir();

    final commandPort = ReceivePort();
    final responsePort = ReceivePort();

    final isolate = await Isolate.spawn(_isolateEntryPoint, [
      commandPort.sendPort,
      responsePort.sendPort,
      appSupportPath,
    ]);

    final sendPort = await commandPort.first as SendPort;

    final worker = PromptWorker._(isolate, commandPort, responsePort, sendPort);

    responsePort.listen((message) {
      if (message is List && message.length == 2) {
        final id = message[0] as int;
        final data = message[1];
        final completer = worker._pending.remove(id);
        if (completer != null) {
          if (data is Map && data.containsKey('error')) {
            completer.completeError(Exception(data['error'] as String));
          } else {
            completer.complete(data);
          }
        }
      }
    });

    await worker._send('init', null);

    return worker;
  }

  Future<dynamic> _send(String command, dynamic data) async {
    final id = _requestId++;
    final completer = Completer<dynamic>();
    _pending[id] = completer;

    _sendPort.send([id, command, data]);
    return completer.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        _pending.remove(id);
        // A synchronous regex (ReDoS) or other runaway computation can hang
        // the isolate forever. Kill it so it stops burning CPU and so the
        // next ensureInitialized() respawns a fresh worker — otherwise every
        // subsequent prompt request would also time out.
        _killAndInvalidate();
        throw TimeoutException(
          'PromptWorker request timed out after 60s',
          const Duration(seconds: 60),
        );
      },
    );
  }

  /// Kills the isolate, closes ports, errors out all pending requests, and
  /// clears the singleton so the next [ensureInitialized] recreates it.
  void _killAndInvalidate() {
    _isolate.kill(priority: Isolate.immediate);
    _commandPort.close();
    _responsePort.close();
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(
          TimeoutException('PromptWorker isolate killed after timeout'),
        );
      }
    }
    _pending.clear();
    if (_instance == this) {
      _instance = null;
    }
  }

  Future<PromptResult> buildPrompt(PromptPayload payload) async {
    final json = jsonEncode(serializePayload(payload));
    final response = await _send('buildPrompt', json) as String;
    return deserializeResult(jsonDecode(response) as Map<String, dynamic>);
  }

  /// Builds a complete prompt from raw inputs. This runs memory injection,
  /// lorebook scanning, prompt assembly, and tokenization all in the isolate.
  Future<PromptResult> buildFromInputs(PromptInputs inputs) async {
    final json = jsonEncode(inputs.toJson());
    final response = await _send('buildFromInputs', json) as String;
    return deserializeResult(jsonDecode(response) as Map<String, dynamic>);
  }

  void dispose() {
    _commandPort.close();
    _responsePort.close();
    _isolate.kill(priority: Isolate.immediate);
    _instance = null;
  }
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
    final visibleHistory = inputs.history
        .where((m) => !m.isHidden && !m.isTyping)
        .toList();
    final scanText = visibleHistory
        .map((m) => m.content)
        .join('\n')
        .toLowerCase();
    final keywordMatched = <String, List<String>>{};
    for (final entry in inputs.memoryEntries) {
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

    final budget = MemoryInjectionBudget.composeBudget(
      contextBudgetTokens: inputs.memoryContextBudgetTokens > 0
          ? inputs.memoryContextBudgetTokens
          : null,
      percent: inputs.memoryMaxInjectionBudgetPercent,
      absoluteCap: inputs.memoryMode == 'legacy'
          ? null
          : inputs.memoryMaxInjectedTokens,
    );

    memorySelection = MemorySelector.select(
      MemorySelectionInput(
        selectionMode: inputs.memoryMode == 'legacy' ? 'legacy' : 'v2',
        entries: inputs.memoryEntries,
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
    final useExcerptPacking =
        inputs.memoryExcerptingEnabled ||
        inputs.memoryPackingMode == 'chunk_first';
    final excerptSelection = useExcerptPacking
        ? MemoryExcerptSelector.select(
            memorySelection,
            packingMode: inputs.memoryPackingMode,
            maxExcerptTokensPerEntry: inputs.memoryExcerptTokensPerChunk,
            maxExcerptChunksPerEntry: inputs.memoryExcerptChunksPerEntry,
            chunkFirstTopEntries: inputs.chunkFirstTopEntries,
            chunkFirstTopChunks: inputs.chunkFirstTopChunks,
          )
        : MemoryExcerptSelector.fullEntries(memorySelection);

    final topEntries = excerptSelection.entries;

    if (excerptSelection.items.isNotEmpty) {
      final macroContent = formatMemoryItems(
        excerptSelection.items,
        includeContextHeader: false,
      );
      final contentParts = <String>[];
      if (inputs.summaryContent != null && inputs.summaryContent!.isNotEmpty) {
        contentParts.add('Summary excerpt:\n${inputs.summaryContent}');
      }
      contentParts.add(
        formatMemoryItems(excerptSelection.items, includeContextHeader: true),
      );

      memoryContent = contentParts.join('\n\n');
      memoryMacroContent = macroContent;
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
  final memoryInjectionFingerprint = memoryContent != null && memoryContent.isNotEmpty
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
  );

  // 3. Build prompt (lorebook scanning happens inside buildPrompt)
  return buildPrompt(payload);
}

bool _glazeMatch(String key, String text) {
  return glazeCheckMatch(key, text, false, WholeWordMode.glaze);
}

