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

/// How an injected block reaches the main request.
enum InjectionTarget {
  /// Appended to the last [BlockConfig.injectLastN] replies in the history,
  /// each carrying its own result. This app's own model.
  @JsonValue('history')
  history,

  /// The latest result as one prompt block, placed by [InjectionRole],
  /// [InjectionPosition] and depth — the original extension's model.
  @JsonValue('prompt')
  prompt,
}
