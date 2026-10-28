import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/llm/tools/llm_tool_call.dart';
import '../../core/llm/transport/llm_protocol.dart';
import '../../core/models/api_config.dart';
import 'character_tools.dart';
import 'model_tool.dart';

/// Tool rounds one reply may run before the model has to answer in text.
const int kMaxToolRounds = 6;

/// Longest result handed back to the model, in UTF-16 units.
const int _maxResultLength = 32 * 1024;

/// The tools one connection offers the chat model.
class ModelToolset {
  const ModelToolset(this.tools);

  /// What [config] has switched on — nothing when tool calling is off or its
  /// protocol cannot report calls back.
  factory ModelToolset.forConfig(ApiConfig config) {
    if (!config.toolCalling ||
        !LlmProtocol.supportsToolCalling(
          config.protocol,
          useResponsesApi: config.useResponsesApi,
        )) {
      return const ModelToolset([]);
    }
    final enabled = {
      for (final group in ModelToolGroup.values)
        if (!config.disabledToolGroups.contains(group.id)) group,
    };
    // Reading the library only makes sense next to something that writes it.
    if (enabled.isEmpty) return const ModelToolset([]);
    return ModelToolset([
      for (final tool in characterTools)
        if (tool.group == null || enabled.contains(tool.group)) tool,
    ]);
  }

  final List<ModelTool> tools;

  bool get isEmpty => tools.isEmpty;

  List<Map<String, dynamic>> get definitions => [
    for (final tool in tools) tool.definition,
  ];

  /// Runs [turn]'s calls one after another, in the order the model made
  /// them, and returns each call's result text keyed by call id. Never
  /// throws: every failure becomes an `{ok: false}` result the model reads.
  /// Calls left once the reply is stopped are answered as cancelled without
  /// running.
  Future<Map<String, String>> run(
    LlmToolTurn turn,
    ModelToolContext context,
  ) async {
    final results = <String, String>{};
    for (final call in turn.calls) {
      results[call.id] = _encode(await _runOne(call, context));
    }
    return results;
  }

  Future<Map<String, Object?>> _runOne(
    LlmToolCall call,
    ModelToolContext context,
  ) async {
    if (context.isAborted()) {
      return _failure(
        const ModelToolError('cancelled', 'The reply was stopped.'),
      );
    }
    final tool = tools.where((t) => t.name == call.name).firstOrNull;
    if (tool == null) {
      return _failure(
        ModelToolError(
          'unknown_tool',
          'No tool named "${call.name}" is available.',
          details: {
            'available': [for (final t in tools) t.name],
          },
        ),
      );
    }
    final arguments = call.arguments;
    if (arguments == null) {
      return _failure(
        const ModelToolError(
          'invalid_arguments',
          'Arguments must be a JSON object.',
        ),
      );
    }
    try {
      return {'ok': true, 'result': await tool.run(context, arguments)};
    } on ModelToolError catch (e) {
      return _failure(e);
    } catch (e, stack) {
      debugPrint('[ModelTools] ${call.name} failed: $e\n$stack');
      return _failure(
        const ModelToolError('internal_error', 'The tool failed unexpectedly.'),
      );
    }
  }

  static Map<String, Object?> _failure(ModelToolError e) => {
    'ok': false,
    'error': {
      'code': e.code,
      'message': e.message,
      if (e.details != null) 'details': e.details,
    },
  };

  static String _encode(Map<String, Object?> envelope) {
    final text = jsonEncode(envelope);
    if (text.length <= _maxResultLength) return text;
    return jsonEncode({
      'ok': envelope['ok'],
      'truncated': true,
      'preview': text.substring(0, _maxResultLength),
    });
  }
}
