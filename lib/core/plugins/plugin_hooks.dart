import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Outcome of the plugin `input:beforeSend` chain.
class PluginSendHookResult {
  const PluginSendHookResult({
    required this.text,
    this.cancelled = false,
    this.cancelledBy,
    this.message,
  });

  /// Text after every handler that committed an edit.
  final String text;
  final bool cancelled;
  final String? cancelledBy;
  final String? message;
}

/// Outcome of running the plugin file handlers on an attached file: the text
/// to insert, or why there is none ([handled] is false when no handler took
/// the file).
class PluginFileExtraction {
  const PluginFileExtraction({this.content, this.handled = true, this.error});

  final String? content;
  final bool handled;
  final String? error;
}

/// What the chat pipeline may ask of the plugins running in one chat.
///
/// Implemented by the plugin runtime (`features/plugins`); the chat pipeline
/// only sees this port so it does not depend on the plugin feature.
abstract interface class PluginHookRunner {
  /// `send:before`: may rewrite or cancel the text about to be sent.
  Future<PluginSendHookResult> beforeSend(
    String text, {
    required String source,
  });

  /// `generation:prepare`: may rewrite the latest user text for this one
  /// request. Never persisted.
  Future<String> prepareGeneration(
    String text, {
    required String source,
    required String generationId,
  });

  /// `generation:success`: may rewrite the finished reply before it is
  /// saved. An empty result keeps [text].
  Future<String> finishGeneration(
    String text, {
    required String source,
    required String generationId,
  });

  /// Lower-case extensions the plugin file handlers accept.
  Set<String> get fileExtensions;

  /// Turns an attached file into text through the first matching handler
  /// that does not answer `unsupported_format`.
  Future<PluginFileExtraction> extractFile(String name, Uint8List bytes);

  /// Fire-and-forget notification (`send:after`, `generation:error`,
  /// `generation:cancelled`, …).
  void notify(String type, Map<String, Object?> payload);
}

/// Per-chat registry of active [PluginHookRunner]s, keyed by character id —
/// the same key the chat providers use.
class PluginHookRegistry {
  final Map<String, PluginHookRunner> _byChat = {};

  void register(String charId, PluginHookRunner runner) =>
      _byChat[charId] = runner;

  /// Identity-checked so a runtime being replaced cannot drop its successor.
  void unregister(String charId, PluginHookRunner runner) {
    if (identical(_byChat[charId], runner)) _byChat.remove(charId);
  }

  PluginHookRunner? forChat(String charId) => _byChat[charId];
}

final pluginHookRegistryProvider = Provider<PluginHookRegistry>(
  (ref) => PluginHookRegistry(),
);
