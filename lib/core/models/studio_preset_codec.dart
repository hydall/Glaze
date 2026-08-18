import 'dart:convert';

import '../llm/studio/studio_context.dart';
import '../llm/studio_controller_ontology.dart';
import 'studio_config.dart';
import 'studio_agent_codec.dart';
import 'ledger_prompt_injection_mode.dart';
import 'ledger_prompt_injection_policy.dart';

final class StudioBlockCanonicalizationResult {
  final StudioPresetBlock block;
  final String? warning;

  const StudioBlockCanonicalizationResult(this.block, {this.warning});
}

final class StudioPresetDecodeResult {
  final StudioPreset preset;
  final LedgerPromptInjectionPolicy ledgerPromptInjectionPolicy;
  final List<String> warnings;

  const StudioPresetDecodeResult(
    this.preset, {
    required this.ledgerPromptInjectionPolicy,
    this.warnings = const [],
  });
}

/// The sole compatibility boundary between persisted legacy Studio JSON and
/// the canonical typed runtime model.
abstract final class StudioPresetCodec {
  static const _legacyContextSlots = <String, StudioContextSlot>{
    'char_card': StudioContextSlot.characterCard,
    'char_personality': StudioContextSlot.characterPersonality,
    'user_persona': StudioContextSlot.userPersona,
    'scenario': StudioContextSlot.scenario,
    'example_dialogue': StudioContextSlot.exampleDialogue,
    'authors_note': StudioContextSlot.authorsNote,
    'summary': StudioContextSlot.summary,
    'memory': StudioContextSlot.memory,
    'worldInfoBefore': StudioContextSlot.loreBefore,
    'worldInfoAfter': StudioContextSlot.loreAfter,
    'lorebooks': StudioContextSlot.loreMacro,
    'recalled_messages': StudioContextSlot.recalledMessages,
    'character_knowledge': StudioContextSlot.characterKnowledge,
    'studio_session_state': StudioContextSlot.studioSessionState,
    'guided_generation': StudioContextSlot.runtimeDynamic,
  };

  static const _seededTargets = <String, String>{
    'continuity_task': 'continuity',
    'continuity_task_universal': 'continuity',
    'continuity_task_orig': 'continuity',
    'agency_task': 'agency',
    'narrative_task': 'narrative',
    'narrative_task_universal': 'narrative',
    'narrative_task_orig': 'narrative',
    'dialogue_task': 'dialogue',
    'guard_task': 'guard_ru',
    'guard_ru_task': 'guard_ru',
    'guard_en_task': 'guard_en',
    'world_task': 'world',
    'meta_task': 'meta',
    'beauty_task': 'beauty',
  };

  static const _targetAliases = <String, List<String>>{
    'continuity': ['continuity'],
    'agency': ['agency', 'character'],
    'narrative': ['narrative', 'pacing', 'style'],
    'dialogue': ['dialogue'],
    'guard_ru': ['guard_ru', 'guard', 'loop', 'prose'],
    'guard_en': ['guard_en'],
    'world': ['world', 'npc'],
    'meta': ['meta', 'ooc', 'lumia'],
    'beauty': ['beauty'],
  };

  static StudioPresetDecodeResult decodePreset(Map<String, dynamic> json) {
    final warnings = <String>[];
    final blocks = <StudioPresetBlock>[];
    final rawBlocks = json['blocks'];
    if (rawBlocks is List) {
      for (final value in rawBlocks) {
        if (value is! Map) {
          warnings.add('Skipped a non-object Studio block.');
          continue;
        }
        final result = canonicalizeBlock(Map<String, dynamic>.from(value));
        blocks.add(result.block);
        if (result.warning != null) warnings.add(result.warning!);
      }
    }
    final enabled = <String, bool>{};
    final rawEnabled = json['agentEnabled'];
    if (rawEnabled is Map) {
      for (final entry in rawEnabled.entries) {
        enabled[entry.key.toString()] = entry.value == true;
      }
    }
    final restoreState = _stringListMap(json['agentBlockRestoreState']);
    final alternativeBlockIds = _stringListMap(
      json['controllerAlternativeBlockIds'],
    );
    final presetId = _string(json['id']);
    List<StudioAgent> agents;
    final rawAgents = json['agents'];
    if (rawAgents is List) {
      agents = const [];
      try {
        agents = StudioAgentCodec.decodeAgentsJson(jsonEncode(rawAgents));
      } on Object {
        warnings.add('Malformed Studio agents were disabled.');
      }
    } else if (!json.containsKey('agents')) {
      agents = StudioControllerOntology.buildDefaultAgents(
        sessionId: presetId,
        now: _integer(json['updatedAt']),
      );
    } else {
      agents = const [];
      warnings.add('Malformed Studio agents were disabled.');
    }
    var runtime = const StudioRuntimeSettings();
    if (json.containsKey('runtime')) {
      final rawRuntime = json['runtime'];
      if (rawRuntime is Map) {
        try {
          final runtimeJson = _jsonMap(rawRuntime);
          final rawRequestedMode =
              runtimeJson['requestedLedgerPromptInjectionMode'];
          if (rawRequestedMode != null &&
              _enumByName(LedgerPromptInjectionMode.values, rawRequestedMode) ==
                  null) {
            // Preserve the runtime object but fail an unsupported request to
            // legacy rather than resetting unrelated settings.
            runtimeJson['requestedLedgerPromptInjectionMode'] = 'legacy';
          }
          runtime = StudioRuntimeSettings.fromJson(runtimeJson).copyWith(
            version: 1,
            // The legacy post-generation selector is retained in JSON only for
            // compatibility. Per-turn extraction always uses the current path;
            // Card Rewriter settings own reconciliation automation.
            ledgerEngine: StudioLedgerEngine.currentReconciled,
          );
        } on Object {
          warnings.add(
            'Malformed Studio runtime settings were reset to defaults.',
          );
        }
      } else {
        warnings.add(
          'Malformed Studio runtime settings were reset to defaults.',
        );
      }
    }
    final rawBlockValues = rawBlocks is List
        ? rawBlocks.cast<Object?>()
        : const <Object?>[];
    // Derive against raw authored blocks here, before any caller can resolve
    // groups. The effective value is intentionally not persisted over absent
    // requested settings, preserving backward-compatible JSON round trips.
    final ledgerPromptInjectionPolicy =
        deriveLedgerPromptInjectionPolicyFromRaw(
          presetId: presetId,
          rawBlocks: rawBlockValues,
          requestedMode: runtime.requestedLedgerPromptInjectionMode,
          requestedAlgorithmVersion:
              runtime.requestedLedgerPromptInjectionAlgorithmVersion,
        );
    return StudioPresetDecodeResult(
      StudioPreset(
        id: presetId,
        name: _string(json['name']),
        blocks: blocks,
        agents: agents,
        expensiveApiConfigId: _string(json['expensiveApiConfigId']),
        cheapApiConfigId: _string(json['cheapApiConfigId']),
        cleanerApiConfigId: _string(json['cleanerApiConfigId']),
        ledgerApiConfigId: _string(json['ledgerApiConfigId']),
        maxFinalHistoryMessages: _integer(
          json['maxFinalHistoryMessages'],
          fallback: 30,
        ),
        agentEnabled: enabled,
        agentBlockRestoreState: restoreState,
        controllerAlternativeBlockIds: alternativeBlockIds,
        runtime: runtime,
        updatedAt: _integer(json['updatedAt']),
      ),
      ledgerPromptInjectionPolicy: ledgerPromptInjectionPolicy,
      warnings: warnings,
    );
  }

  static StudioBlockCanonicalizationResult canonicalizeBlock(
    Map<String, dynamic> json,
  ) {
    final id = _string(json['id']);
    final title = _string(json['title'], _string(json['name']));
    final attemptsLedgerHeader =
        id == ledgerPromptInjectionHeaderId ||
        title == ledgerPromptInjectionHeaderTitle;
    // A non-boolean authored value is malformed, not truthy. Preserve the
    // attempted known control as a disabled typed sentinel so policy derived
    // later from StudioPreset (after a DB round trip) remains fail-closed.
    final invalidLedgerHeaderEnabled =
        attemptsLedgerHeader &&
        json.containsKey('enabled') &&
        json['enabled'] != null &&
        json['enabled'] is! bool;
    final canonicalType = _enumByName(StudioBlockType.values, json['type']);
    final canonicalSlot = _enumByName(
      StudioContextSlot.values,
      json['contextSlot'],
    );
    if (canonicalType != null) {
      final missingSlot =
          canonicalType == StudioBlockType.context && canonicalSlot == null;
      return StudioBlockCanonicalizationResult(
        _block(
          json,
          id: id,
          title: title,
          type: canonicalType,
          contextSlot: canonicalSlot,
          targetAgentId: _nullableString(json['targetAgentId']),
          forceDisabled: missingSlot || invalidLedgerHeaderEnabled,
        ),
        warning: missingSlot
            ? 'Studio context block "$id" has no valid contextSlot and was disabled.'
            : null,
      );
    }

    final kind = _string(json['kind']);
    if (kind == 'previous_agents') {
      return StudioBlockCanonicalizationResult(
        _block(
          json,
          id: id,
          title: title,
          type: StudioBlockType.priorBriefs,
          forceDisabled: invalidLedgerHeaderEnabled,
        ),
      );
    }
    if (kind == 'chat_history') {
      return StudioBlockCanonicalizationResult(
        _block(
          json,
          id: id,
          title: title,
          type: StudioBlockType.history,
          forceDisabled: invalidLedgerHeaderEnabled,
        ),
      );
    }
    final projection = switch (kind) {
      'static_context' => StudioContextSlot.staticContext,
      'dynamic_context' => StudioContextSlot.dynamicContext,
      _ => _legacyContextSlots[kind],
    };
    if (projection != null) {
      return StudioBlockCanonicalizationResult(
        _block(
          json,
          id: id,
          title: title,
          type: StudioBlockType.context,
          contextSlot: projection,
          forceDisabled: invalidLedgerHeaderEnabled,
        ),
      );
    }
    if (kind == 'tracker_instruction') {
      final target = _resolveLegacyTarget(id, title);
      final unresolved = target == null;
      return StudioBlockCanonicalizationResult(
        _block(
          json,
          id: id,
          title: title,
          type: StudioBlockType.instruction,
          targetAgentId: target,
          forceDisabled: unresolved || invalidLedgerHeaderEnabled,
        ),
        warning: unresolved
            ? 'Tracker instruction "$id" has no unique target and was disabled.'
            : null,
      );
    }

    const knownInstructions = {
      'custom_text',
      'slot',
      'instruction',
      'agent_instruction',
      'group_open',
      'group_close',
    };
    final content = _string(json['content']);
    final unknownBlank =
        !knownInstructions.contains(kind) && content.trim().isEmpty;
    return StudioBlockCanonicalizationResult(
      _block(
        json,
        id: id,
        title: title,
        type: StudioBlockType.instruction,
        forceDisabled: unknownBlank || invalidLedgerHeaderEnabled,
      ),
      warning: unknownBlank
          ? 'Unknown blank Studio block "$id" was disabled.'
          : null,
    );
  }

  static Map<String, dynamic> canonicalizePresetJson(
    Map<String, dynamic> json,
  ) {
    final preset = decodePreset(json).preset;
    return {
      'id': preset.id,
      'name': preset.name,
      'blocks': [for (final block in preset.blocks) block.toJson()],
      'agents': [for (final agent in preset.agents) agent.toJson()],
      'expensiveApiConfigId': preset.expensiveApiConfigId,
      'cheapApiConfigId': preset.cheapApiConfigId,
      'cleanerApiConfigId': preset.cleanerApiConfigId,
      'ledgerApiConfigId': preset.ledgerApiConfigId,
      'maxFinalHistoryMessages': preset.maxFinalHistoryMessages,
      'agentEnabled': preset.agentEnabled,
      'agentBlockRestoreState': preset.agentBlockRestoreState,
      'controllerAlternativeBlockIds': preset.controllerAlternativeBlockIds,
      'runtime': encodeRuntime(preset.runtime),
      'updatedAt': preset.updatedAt,
    };
  }

  static Map<String, dynamic> canonicalizeBlockJson(
    Map<String, dynamic> json,
  ) => canonicalizeBlock(json).block.toJson();

  static String canonicalizeBlocksJson(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! List) {
      throw const FormatException('Studio blocks JSON must be a list.');
    }
    return jsonEncode([
      for (final value in decoded)
        canonicalizeBlockJson(Map<String, dynamic>.from(value as Map)),
    ]);
  }

  static Map<String, dynamic> encodeRuntime(StudioRuntimeSettings runtime) =>
      _jsonMap(runtime.toJson());

  static Map<String, dynamic> _jsonMap(Object value) =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

  static Map<String, List<String>> _stringListMap(Object? value) {
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries)
        if (entry.value is List)
          entry.key.toString(): [
            for (final item in entry.value as List) item.toString(),
          ],
    };
  }

  static StudioPresetBlock _block(
    Map<String, dynamic> json, {
    required String id,
    required String title,
    required StudioBlockType type,
    StudioContextSlot? contextSlot,
    String? targetAgentId,
    bool forceDisabled = false,
  }) => StudioPresetBlock(
    id: id,
    title: title,
    type: type,
    contextSlot: contextSlot,
    targetAgentId: targetAgentId,
    role: _string(json['role'], 'system'),
    content: _string(json['content']),
    enabled: forceDisabled ? false : json['enabled'] != false,
    locked: json['locked'] == true,
    order: _integer(json['order']),
    section: _string(
      json['section'],
      json.containsKey('injectionPoint') ? '' : 'pregen',
    ),
    mode: _string(json['mode'], 'direct'),
    isStatic: json['isStatic'] == true,
    injectionPoint: _string(json['injectionPoint'], 'pregen'),
    sourceAgentId: _string(json['sourceAgentId']),
    groupBoundary: _string(json['groupBoundary'], 'none'),
    insertionMode: _string(json['insertionMode'], 'relative'),
    depth: json['depth'] is num ? (json['depth'] as num).toInt() : null,
  );

  static String? _resolveLegacyTarget(String id, String title) {
    final seeded = _seededTargets[id];
    if (seeded != null) return seeded;
    final text = '$id\n$title'.toLowerCase();
    final matches = <String>{
      for (final entry in _targetAliases.entries)
        if (entry.value.any(text.contains)) entry.key,
    };
    return matches.length == 1 ? matches.single : null;
  }

  static T? _enumByName<T extends Enum>(List<T> values, Object? value) {
    if (value is! String) return null;
    for (final candidate in values) {
      if (candidate.name == value) return candidate;
    }
    return null;
  }

  static String _string(Object? value, [String fallback = '']) =>
      value is String ? value : fallback;

  static String? _nullableString(Object? value) =>
      value is String && value.trim().isNotEmpty ? value : null;

  static int _integer(Object? value, {int fallback = 0}) =>
      value is num ? value.toInt() : fallback;
}
