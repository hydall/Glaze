import 'dart:collection';

import '../history_assembler.dart';
import 'prompt_result.dart';
import 'prompt_payload.dart';

enum MainModelContextSource { standardPrompt, studioFinalWriter }

/// Transient context captured immediately before the main/final-writer request.
/// It is intentionally not persisted: API keys are absent and manual reruns
/// after a restart use the documented reconstructed-context fallback.
class MainModelContextSnapshot {
  final List<Map<String, dynamic>> providerMessages;
  final PromptResult promptResult;
  final PromptPayload promptPayload;
  final MainModelContextSource source;

  bool get isStudioFinalWriter =>
      source == MainModelContextSource.studioFinalWriter;

  /// Metadata-bearing prompt messages are available only when providerMessages
  /// were built directly from this PromptResult. Studio final-writer messages
  /// are reordered and augmented by StudioMessageBuilder, so the base
  /// PromptResult must not be used to selectively filter them.
  List<PromptMessage>? get filterablePromptMessages =>
      source == MainModelContextSource.standardPrompt
      ? promptResult.messages
      : null;

  MainModelContextSnapshot({
    required List<Map<String, dynamic>> providerMessages,
    required this.promptResult,
    required this.promptPayload,
    MainModelContextSource? source,
    bool isStudioFinalWriter = false,
  }) : source =
           source ??
           (isStudioFinalWriter
               ? MainModelContextSource.studioFinalWriter
               : MainModelContextSource.standardPrompt),
       providerMessages = List.unmodifiable(
         providerMessages.map(_immutableMap),
       );
}

Map<String, dynamic> _immutableMap(Map<String, dynamic> source) =>
    UnmodifiableMapView(
      source.map((key, value) => MapEntry(key, _immutableValue(value))),
    );

Object? _immutableValue(Object? value) {
  if (value is Map) {
    return UnmodifiableMapView(
      value.map(
        (key, child) => MapEntry(key.toString(), _immutableValue(child)),
      ),
    );
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_immutableValue));
  }
  return value;
}
