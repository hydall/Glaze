import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/context_calculator.dart';
import '../../../core/llm/prompt_isolate.dart';
import '../providers/prompt_build_providers.dart';
import '../../../core/models/preset.dart';
import '../../../core/state/active_selection_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/summary_providers.dart';
import '../../extensions/providers/extension_presets_provider.dart';
import '../../extensions/providers/extensions_settings_provider.dart';
import '../../image_gen/image_gen_provider.dart';
import '../../settings/api_list_provider.dart';
import '../chat_provider.dart';
import '../state/cached_token_breakdown.dart';
import '../state/token_breakdown_cache.dart';
import '../widgets/magic_drawer_models.dart';

class MagicDrawerStatsService {
  final WidgetRef _ref;

  MagicDrawerStatsService(this._ref);

  bool _isCalculating = false;
  bool _pendingRecalc = false;
  String? _pendingCharId;
  MagicDrawerStats? _pendingBase;

  Future<MagicDrawerStats> computeStats(String charId) async {
    final chatState = _ref.read(chatProvider(charId)).value;
    final session = chatState?.session;
    final charRepo = _ref.read(characterRepoProvider);
    final presetRepo = _ref.read(presetRepoProvider);
    final personaRepo = _ref.read(personaRepoProvider);
    final lorebookRepo = _ref.read(lorebookRepoProvider);
    final memoryRepo = _ref.read(memoryBookRepoProvider);

    final character = await charRepo.getById(charId);
    final presets = await presetRepo.getAll();
    final personas = await personaRepo.getAll();
    await _ref.read(apiListProvider.future);
    final lorebooks = await lorebookRepo.getAll();
    final activePresetId = _ref.read(activePresetIdProvider);
    final activePersonaId = _ref.read(activePersonaIdProvider);
    final activePreset = activePresetId != null
        ? presets.where((p) => p.id == activePresetId).firstOrNull
        : presets.firstOrNull;
    final activePersona = activePersonaId != null
        ? personas.where((p) => p.id == activePersonaId).firstOrNull
        : personas.firstOrNull;
    final chatApi = _ref.read(activeApiConfigProvider);
    List<PresetRegex> regexes;
    try {
      regexes = await _ref.read(activeRegexesProvider.future);
    } catch (e) {
      debugPrint('[MagicDrawer] activeRegexesProvider error: $e');
      regexes = [];
    }

    var summaryChars = 0;
    var memoryEntries = 0;
    var sessionCount = 0;
    var messageCount = 0;
    String? summaryContent;

    if (session != null) {
      try {
        final summary = await _ref
            .read(summaryServiceProvider)
            .getSummary(session.id);
        summaryContent = summary;
        summaryChars = summary?.length ?? 0;
      } catch (e) {
        debugPrint('[MagicDrawer] summary error: $e');
      }

      try {
        final memoryBook = await memoryRepo.getBySessionId(session.id);
        memoryEntries = memoryBook?.entries.length ?? 0;
        sessionCount =
            (await _ref.read(chatRepoProvider).getByCharacterId(charId)).length;
        messageCount = session.messages.length;
      } catch (e) {
        debugPrint('[MagicDrawer] session stats error: $e');
      }
    }

    bool imageGenEnabled = false;
    try {
      imageGenEnabled =
          _ref.read(imageGenSettingsProvider).value?.enabled == true;
    } catch (_) {}

    final extSettings = _ref.read(extensionsSettingsProvider);
    final extPresets = _ref.read(extensionPresetsProvider);
    final extActivePresetName = extSettings.activePresetId == null
        ? null
        : extPresets
              .where((p) => p.id == extSettings.activePresetId)
              .firstOrNull
              ?.name;

    final cached = _ref.read(cachedTokenBreakdownProvider(charId));

    final approxHistoryTokens = session != null
        ? session.messages
              .where((m) => !m.isHidden && !m.isTyping)
              .fold<int>(0, (sum, m) => sum + (m.content.length / 4).round())
        : 0;

    final lastMsg = session?.messages.lastOrNull;
    final lorebookEntryCount = lastMsg?.triggeredLorebooks.length ?? 0;

    return MagicDrawerStats(
      character: character,
      activePreset: activePreset,
      activePersona: activePersona,
      apiConfig: chatApi,
      session: session,
      sessionCount: sessionCount,
      messageCount: messageCount,
      lorebookEntryCount: lorebookEntryCount,
      memoryEntryCount: memoryEntries,
      regexCount: regexes.length,
      summaryChars: summaryChars,
      promptTokens: cached?.totalTokens ?? 0,
      approximateHistoryTokens: approxHistoryTokens,
      contextSize: chatApi?.contextSize ?? 0,
      characterTokens: (cached?.sourceTokens['description'] ?? 0) > 0
          ? cached!.sourceTokens['description']!
          : (cached?.macroTokens['description'] ?? 0),
      presetTokens: cached?.presetNetTokens ?? 0,
      personaTokens: (cached?.sourceTokens['persona'] ?? 0) > 0
          ? cached!.sourceTokens['persona']!
          : (cached?.macroTokens['persona'] ?? 0),
      summaryTokens: (cached?.sourceTokens['summary'] ?? 0) > 0
          ? cached!.sourceTokens['summary']!
          : (cached?.macroTokens['summary'] ?? 0),
      vectorLoreTokens: cached?.vectorLoreTokens ?? 0,
      keywordLoreTokens:
          ((cached?.sourceTokens['lorebook'] ?? 0) +
          (cached?.macroTokens['lorebooks'] ?? 0)),
      imageGenEnabled: imageGenEnabled,
      lorebooks: lorebooks,
      summaryContent: summaryContent,
      extBlocksEnabled: extSettings.enabled,
      extBlocksActivePresetName: extActivePresetName,
    );
  }

  Future<MagicDrawerStats> computeTokenStats(
    String charId,
    MagicDrawerStats base,
  ) async {
    final session = base.session;
    final character = base.character;
    final chatApi = base.apiConfig;

    if (session == null || character == null || chatApi == null) return base;

    if (_isCalculating) {
      _pendingRecalc = true;
      _pendingCharId = charId;
      _pendingBase = base;
      return base;
    }

    _isCalculating = true;
    try {
      final visibleCount = session.messages.where((m) => !m.isHidden).length;
      final hash = TokenBreakdownCache.computeHash(
        charId: charId,
        sessionId: session.id,
        messageCount: visibleCount,
        contextSize: chatApi.contextSize,
        maxTokens: chatApi.maxTokens,
        authorsNote: session.authorsNote?.content ?? '',
        summary: base.summaryContent ?? '',
      );

      final cached = TokenBreakdownCache.get(hash);
      if (cached != null) {
        _ref.read(cachedTokenBreakdownProvider(charId).notifier).state = cached;
        return base.copyWith(
          promptTokens: cached.totalTokens,
          characterTokens: (cached.sourceTokens['description'] ?? 0) > 0
              ? cached.sourceTokens['description']!
              : (cached.macroTokens['description'] ?? 0),
          presetTokens: cached.presetNetTokens,
          personaTokens: (cached.sourceTokens['persona'] ?? 0) > 0
              ? cached.sourceTokens['persona']!
              : (cached.macroTokens['persona'] ?? 0),
          summaryTokens: (cached.sourceTokens['summary'] ?? 0) > 0
              ? cached.sourceTokens['summary']!
              : (cached.macroTokens['summary'] ?? 0),
          vectorLoreTokens: cached.vectorLoreTokens,
          keywordLoreTokens:
              (cached.sourceTokens['lorebook'] ?? 0) +
              (cached.macroTokens['lorebooks'] ?? 0),
        );
      }

      final builder = _ref.read(promptPayloadBuilderProvider);
      final inputs = await builder.collectInputs(
        charId: charId,
        session: session,
      );
      final result = await buildFromInputsInIsolate(inputs);
      var breakdown = result.breakdown;

      final lastVectorTokens = _ref.read(lastVectorLoreTokensProvider(charId));
      if (lastVectorTokens > 0 && breakdown.vectorLoreTokens == 0) {
        final newSources = Map<String, int>.from(breakdown.sourceTokens)
          ..['vectorLore'] = lastVectorTokens;
        breakdown = TokenBreakdown(
          sourceTokens: newSources,
          macroTokens: breakdown.macroTokens,
          staticTotal: breakdown.staticTotal,
          historyBudget: breakdown.historyBudget,
          historyTokens: breakdown.historyTokens,
          totalTokens: breakdown.totalTokens + lastVectorTokens,
          cutoffIndex: breakdown.cutoffIndex,
          trimmedHistory: breakdown.trimmedHistory,
          lorebookReserveTokens: breakdown.lorebookReserveTokens,
          memoryTokens: breakdown.memoryTokens,
          vectorLoreTokens: lastVectorTokens,
          fixedTotal: breakdown.fixedTotal + lastVectorTokens,
          remaining: breakdown.remaining - lastVectorTokens,
        );
      }

      final sourceTokens = breakdown.sourceTokens;

      TokenBreakdownCache.set(hash, breakdown);
      _ref.read(cachedTokenBreakdownProvider(charId).notifier).state =
          breakdown;

      return base.copyWith(
        promptTokens: breakdown.totalTokens,
        characterTokens: (sourceTokens['description'] ?? 0) > 0
            ? sourceTokens['description']!
            : (breakdown.macroTokens['description'] ?? 0),
        presetTokens: breakdown.presetNetTokens,
        personaTokens: (sourceTokens['persona'] ?? 0) > 0
            ? sourceTokens['persona']!
            : (breakdown.macroTokens['persona'] ?? 0),
        summaryTokens: (sourceTokens['summary'] ?? 0) > 0
            ? sourceTokens['summary']!
            : (breakdown.macroTokens['summary'] ?? 0),
        vectorLoreTokens: breakdown.vectorLoreTokens,
        keywordLoreTokens:
            (sourceTokens['lorebook'] ?? 0) +
            (breakdown.macroTokens['lorebooks'] ?? 0),
      );
    } catch (e) {
      debugPrint('[MagicDrawer] computeTokenStats error: $e');
      return base;
    } finally {
      _isCalculating = false;
      if (_pendingRecalc) {
        _pendingRecalc = false;
        final cId = _pendingCharId;
        final b = _pendingBase;
        _pendingCharId = null;
        _pendingBase = null;
        if (cId != null && b != null) {
          unawaited(computeTokenStats(cId, b));
        }
      }
    }
  }
}
