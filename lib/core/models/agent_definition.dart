// ignore_for_file: invalid_annotation_target

import 'package:freezed_annotation/freezed_annotation.dart';

import 'preset.dart';

part 'agent_definition.freezed.dart';
part 'agent_definition.g.dart';

/// When an agent runs relative to the reply. See `docs/plans/AGENTS.md`.
abstract final class AgentPhase {
  /// Before the reply: its result can go into the main prompt of this turn.
  static const preGeneration = 'pre_generation';

  /// Together with the reply: it does not see the reply and does not delay
  /// it; its result reaches the main prompt of the next turn.
  static const parallel = 'parallel';

  /// After the reply: it sees the reply and acts on it.
  static const postProcessing = 'post_processing';

  static const all = [preGeneration, parallel, postProcessing];
}

/// What the engine does with an agent's answer.
abstract final class AgentResultType {
  /// The text goes into the main prompt (at the agent's injection point, or
  /// only where `{{agent::id}}` names it).
  static const contextInjection = 'context_injection';

  /// Rewrites the reply into a blue `'cleaned'` sub-swipe (Post Clean engine).
  static const textRewrite = 'text_rewrite';

  /// Updates the tracker state (Ledger engine).
  static const ledgerUpdate = 'ledger_update';

  /// Proposes card edits for review (Card Rewriter engine).
  static const cardUpdateProposal = 'card_update_proposal';

  static const all = [
    contextInjection,
    textRewrite,
    ledgerUpdate,
    cardUpdateProposal,
  ];

  /// Result types an agent of [phase] may have.
  static List<String> allowedFor(String phase) => switch (phase) {
    AgentPhase.postProcessing => const [
      textRewrite,
      ledgerUpdate,
      cardUpdateProposal,
    ],
    _ => const [contextInjection],
  };
}

/// Which connection an agent runs on.
abstract final class AgentConnectionMode {
  /// The chat's own connection.
  static const chat = 'chat';

  /// The shared helper connection (`AgentsSettings.helperApiConfigId`).
  static const helper = 'helper';

  /// A specific saved connection ([AgentConnection.apiConfigId]).
  static const config = 'config';
}

/// Where a `context_injection` result goes in the main prompt.
abstract final class AgentPlacement {
  static const depth = 'depth';
  static const beforeMain = 'before_main';
  static const afterMain = 'after_main';

  /// Nowhere on its own — only where the preset writes `{{agent::id}}`.
  static const macroOnly = 'macro';

  static const all = [depth, beforeMain, afterMain, macroOnly];
}

@freezed
abstract class AgentConnection with _$AgentConnection {
  const factory AgentConnection({
    @Default(AgentConnectionMode.chat) String mode,

    /// Saved connection when [mode] is [AgentConnectionMode.config].
    @Default('') String apiConfigId,

    /// Overrides the connection's model when non-empty.
    @Default('') String model,
  }) = _AgentConnection;

  factory AgentConnection.fromJson(Map<String, dynamic> json) =>
      _$AgentConnectionFromJson(json);
}

/// Generation parameters. A null field is not overridden: the connection's
/// own value applies.
@freezed
abstract class AgentParams with _$AgentParams {
  const factory AgentParams({
    double? temperature,
    double? topP,
    int? maxTokens,
    int? timeoutMs,
    bool? requestReasoning,
  }) = _AgentParams;

  factory AgentParams.fromJson(Map<String, dynamic> json) =>
      _$AgentParamsFromJson(json);
}

/// How often an agent runs. Every gate must pass.
@freezed
abstract class AgentCadence with _$AgentCadence {
  const factory AgentCadence({
    /// Runs on every N-th reply of the chat (1 = every reply).
    @Default(1) int everyN,

    /// When non-empty, runs only if one of these appears (case-insensitive)
    /// in the last [scanDepth] messages.
    @Default([]) List<String> keywords,
    @Default(3) int scanDepth,
  }) = _AgentCadence;

  factory AgentCadence.fromJson(Map<String, dynamic> json) =>
      _$AgentCadenceFromJson(json);
}

@freezed
abstract class AgentInjection with _$AgentInjection {
  const factory AgentInjection({
    @Default(AgentPlacement.depth) String placement,

    /// Messages from the end of the history, for [AgentPlacement.depth].
    @Default(1) int depth,
    @Default('system') String role,
  }) = _AgentInjection;

  factory AgentInjection.fromJson(Map<String, dynamic> json) =>
      _$AgentInjectionFromJson(json);
}

/// One agent of the library: a small helper that runs around the ordinary
/// reply with its own prompt, connection and cadence.
@freezed
abstract class AgentDefinition with _$AgentDefinition {
  const AgentDefinition._();

  // Nested models serialize to maps, so toJson is plain JSON without encoding.
  @JsonSerializable(explicitToJson: true)
  const factory AgentDefinition({
    required String id,
    @Default('') String name,
    @Default('') String description,

    @Default(AgentPhase.preGeneration) String phase,
    @Default(AgentResultType.contextInjection) String resultType,

    /// The agent's prompt — the same block format as an ordinary preset.
    @Default([]) List<PresetBlock> blocks,
    @Default([]) List<PresetBlockFolder> blockFolders,
    @Default(AgentConnection()) AgentConnection connection,
    @Default(AgentParams()) AgentParams params,

    /// How many of the latest chat messages the agent sees.
    @Default(5) int contextSize,
    @Default(AgentCadence()) AgentCadence cadence,

    /// Agents that must run this turn for this one to run.
    @Default([]) List<String> dependsOn,

    /// Agents whose results reach this agent's prompt (`{{agent::id}}`), and
    /// which therefore run before it.
    @Default([]) List<String> seesOutputsOf,
    @Default(AgentInjection()) AgentInjection injection,

    /// Result-type specific settings (e.g. Post Clean's broadcast blocks).
    @Default({}) Map<String, dynamic> settings,

    /// On in every chat that does not say otherwise (see agent bindings).
    @Default(false) bool enabledGlobally,
    @Default(0) int order,
    @Default(0) int updatedAt,
  }) = _AgentDefinition;

  factory AgentDefinition.fromJson(Map<String, dynamic> json) =>
      _$AgentDefinitionFromJson(json);

  String get displayName => name.trim().isEmpty ? id : name.trim();
}
