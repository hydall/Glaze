import 'package:freezed_annotation/freezed_annotation.dart';

/// Role a block's stored output is injected under.
///
/// Serialized as the same integers the original ExtBlocks extension writes, so
/// exported blocks move between the two without a conversion table.
enum InjectionRole {
  @JsonValue(0)
  system,
  @JsonValue(1)
  user,
  @JsonValue(2)
  assistant,
}

/// Where a block's stored output is injected.
enum InjectionPosition {
  /// Straight after the main prompt. Meaningful with the system role.
  @JsonValue(0)
  afterMainPrompt,

  /// Into the chat itself, at a configured depth.
  @JsonValue(1)
  inChat,

  /// Straight before the main prompt. Meaningful with the system role.
  @JsonValue(2)
  beforeMainPrompt,
}
