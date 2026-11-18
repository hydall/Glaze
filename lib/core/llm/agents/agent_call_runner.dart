import 'dart:convert';

import 'package:dio/dio.dart';

import '../../models/agent_definition.dart';
import '../../models/agents_settings.dart';
import '../../models/api_config.dart';
import '../../utils/think_tags.dart';
import '../aux_api_config_resolver.dart';
import '../aux_llm_client.dart';
import '../tokenizer.dart';
import '../transport/llm_capture_context.dart';

/// What one agent call returned.
class AgentCallResult {
  final AgentDefinition agent;
  final bool ok;
  final String output;
  final String? error;
  final String promptJson;
  final int promptTokens;
  final int completionTokens;
  final int durationMs;

  const AgentCallResult({
    required this.agent,
    required this.ok,
    this.output = '',
    this.error,
    this.promptJson = '[]',
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.durationMs = 0,
  });
}

/// The connection [agent] runs on: the chat's, the shared helper connection,
/// or a saved one, with the agent's model override.
AuxApiConfig resolveAgentApiConfig({
  required AgentDefinition agent,
  required List<ApiConfig> apiConfigs,
  required ApiConfig? chatConfig,
  required AgentsSettings settings,
}) {
  final connection = agent.connection;
  final String apiConfigId;
  var model = connection.model;
  switch (connection.mode) {
    case AgentConnectionMode.helper:
      apiConfigId = settings.helperApiConfigId;
      if (model.isEmpty) model = settings.helperModel;
    case AgentConnectionMode.config:
      apiConfigId = connection.apiConfigId;
    default:
      apiConfigId = '';
  }
  return AuxApiConfigResolver.resolve(
    apiConfigs: apiConfigs,
    apiConfigId: apiConfigId,
    fallback: chatConfig,
    errorLabel: 'agent:${agent.id}',
    modelOverride: model,
  );
}

/// Sends one agent request and turns the answer into an [AgentCallResult].
/// Never throws: a failure is a result with [AgentCallResult.ok] false.
class AgentCallRunner {
  final AuxLlmClient llm;

  const AgentCallRunner({this.llm = const AuxLlmClient()});

  static const defaultMaxTokens = 1024;
  static const defaultTimeoutMs = 120000;

  Future<AgentCallResult> run({
    required AgentDefinition agent,
    required List<Map<String, String>> messages,
    required AuxApiConfig config,
    required double fallbackTemperature,
    CancelToken? cancelToken,
    String? sessionId,
    String? messageId,
  }) async {
    final started = DateTime.now();
    final promptJson = jsonEncode(messages);
    final promptTokens = estimateTokens(
      messages.map((m) => m['content'] ?? '').join('\n'),
    );
    int elapsed() => DateTime.now().difference(started).inMilliseconds;
    try {
      final params = agent.params;
      final outcome = await llm.callOnceWithLog(
        config: config,
        messages: messages,
        maxTokens: params.maxTokens ?? defaultMaxTokens,
        temperature: params.temperature ?? fallbackTemperature,
        timeoutMs: params.timeoutMs ?? defaultTimeoutMs,
        cancelToken: cancelToken,
        requestReasoning: params.requestReasoning ?? false,
        omitReasoning: !(params.requestReasoning ?? false),
        captureContext: LlmCaptureContext(
          stage: 'agent.${agent.phase}',
          sessionId: sessionId,
          messageId: messageId,
          agentId: agent.id,
        ),
      );
      final text = outcome.text;
      if (!outcome.isOk || text == null) {
        return AgentCallResult(
          agent: agent,
          ok: false,
          error: outcome.lastError?.toString() ?? outcome.status.name,
          promptJson: promptJson,
          promptTokens: promptTokens,
          durationMs: elapsed(),
        );
      }
      final output = stripThinkTags(text).trim();
      return AgentCallResult(
        agent: agent,
        ok: output.isNotEmpty,
        output: output,
        error: output.isEmpty ? 'empty answer' : null,
        promptJson: promptJson,
        promptTokens: promptTokens,
        completionTokens: estimateTokens(output),
        durationMs: elapsed(),
      );
    } catch (error) {
      return AgentCallResult(
        agent: agent,
        ok: false,
        error: '$error',
        promptJson: promptJson,
        promptTokens: promptTokens,
        durationMs: elapsed(),
      );
    }
  }
}
