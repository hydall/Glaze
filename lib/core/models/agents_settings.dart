import 'package:freezed_annotation/freezed_annotation.dart';

part 'agents_settings.freezed.dart';
part 'agents_settings.g.dart';

/// Global agent settings. Nested inside `PipelineSettings` under `agents`.
@freezed
abstract class AgentsSettings with _$AgentsSettings {
  const factory AgentsSettings({
    /// The shared helper connection agents use in
    /// `AgentConnectionMode.helper`. Empty uses the chat's connection.
    @Default('') String helperApiConfigId,

    /// Overrides the helper connection's model when non-empty.
    @Default('') String helperModel,

    /// Agents that may be waiting on the network at once.
    @Default(4) int maxConcurrent,
  }) = _AgentsSettings;

  factory AgentsSettings.fromJson(Map<String, dynamic> json) =>
      _$AgentsSettingsFromJson(json);
}
