import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/llm/aux_llm_client.dart';
import '../../core/llm/transport/llm_capture_context.dart';
import '../../core/models/api_config.dart';
import '../../core/models/translation_settings.dart';
import '../../core/services/translation_prompt_presets.dart';
import '../../core/state/db_provider.dart';
import '../settings/api_list_provider.dart';
import 'machine_translation_client.dart';
import 'translation_languages.dart';
import 'translation_providers.dart';

final translationServiceProvider = Provider<TranslationService>(
  (ref) => TranslationService(ref),
);

/// Thrown when translation is asked for with no usable engine behind it.
class TranslationNotConfiguredException implements Exception {
  const TranslationNotConfiguredException();

  @override
  String toString() => 'No translation engine configured';
}

/// Floor for the output cap. Matches the transports' own fallback, so asking
/// for it is never rejected, and leaves room for a full reply to come back
/// longer than it went out — Russian runs well past English in tokens.
const int kTranslationMinMaxTokens = 4096;

/// Translates text on whichever engine the Agents tab binds.
///
/// For the per-message button and the composer action this is a side channel
/// and nothing else: it sends the one text it is handed and returns the result.
/// It never reads or writes chat history, never goes through the prompt
/// builder, and its output is only painted on screen or put back into the
/// composer for the user to edit. The two automatic toggles call it from the
/// send path and the post-generation path, where the caller decides what to do
/// with the result.
class TranslationService {
  final Ref _ref;
  final AuxLlmClient llm;
  final MachineTranslationClient machine;

  TranslationService(
    this._ref, {
    this.llm = const AuxLlmClient(),
    MachineTranslationClient? machine,
  }) : machine = machine ?? MachineTranslationClient();

  Future<String> translate({
    required String text,
    required String targetLanguageCode,
    CancelToken? cancelToken,
    String? sessionId,
    String? messageId,
  }) async {
    final settings = _ref.read(pipelineSettingsProvider).translation;
    final language = resolveTranslationLanguage(targetLanguageCode);
    final provider = TranslationProvider.fromId(settings.provider);

    if (provider == TranslationProvider.llm) {
      return _translateWithLlm(
        settings: settings,
        text: text,
        language: language,
        cancelToken: cancelToken,
        sessionId: sessionId,
        messageId: messageId,
      );
    }
    return machine.translate(
      provider: provider,
      text: text,
      target: language,
      apiKey: settings.translatorApiKey,
      endpoint: settings.translatorEndpoint,
      folderId: settings.translatorFolderId,
      cancelToken: cancelToken,
    );
  }

  Future<String> _translateWithLlm({
    required TranslationSettings settings,
    required String text,
    required TranslationLanguage language,
    CancelToken? cancelToken,
    String? sessionId,
    String? messageId,
  }) async {
    final config = await _resolveConfig(settings);
    if (config == null) throw const TranslationNotConfiguredException();

    final raw = await llm.callOnce(
      config: AuxApiConfig(
        endpoint: config.endpoint,
        apiKey: config.apiKey,
        model: config.model,
        protocol: config.protocol,
        useResponsesApi: config.useResponsesApi,
        omitTemperature: config.omitTemperature,
        extraRequestParameters: config.extraRequestParameters,
      ),
      messages: buildTranslationMessages(
        text,
        language,
        template: settings.prompt,
      ),
      maxTokens: math.max(config.maxTokens, kTranslationMinMaxTokens),
      temperature: 0.3,
      timeoutMs: config.firstChunkTimeoutMs,
      cancelToken: cancelToken,
      captureContext: LlmCaptureContext(
        stage: 'translation',
        sessionId: sessionId,
        messageId: messageId,
      ),
    );
    final translated = cleanTranslationOutput(raw);
    if (translated.isEmpty) throw Exception('The translator returned no text');
    return translated;
  }

  Future<ApiConfig?> _resolveConfig(TranslationSettings settings) async {
    // The list can still be loading on a cold start; the active connection
    // the slot falls back to reads null until it resolves.
    await _ref.read(apiListProvider.future);
    final configs = _ref.read(apiListProvider).value ?? const <ApiConfig>[];
    final config = resolveTranslationConfig(
      settings,
      configs: configs,
      active: _ref.read(activeApiConfigProvider),
    );
    return config;
  }
}

/// The connection [settings] point at, with the slot's model folded in. Null
/// when there is none, or when it is an embedding connection.
ApiConfig? resolveTranslationConfig(
  TranslationSettings settings, {
  required List<ApiConfig> configs,
  required ApiConfig? active,
}) {
  ApiConfig? config;
  if (settings.apiConfigId.isNotEmpty) {
    config = configs.where((c) => c.id == settings.apiConfigId).firstOrNull;
  }
  config ??= active;
  if (config == null || config.mode == 'embedding') return null;
  final model = settings.model.trim();
  return model.isEmpty ? config : config.copyWith(model: model);
}

/// The request: a system instruction and the text as the only user turn.
/// Nothing from the chat goes along with it. [template] is the reader's own
/// instruction; empty means the built-in default.
List<Map<String, String>> buildTranslationMessages(
  String text,
  TranslationLanguage language, {
  String template = '',
}) => [
  {
    'role': 'system',
    'content': TranslationPromptPresets.resolve(template, language.englishName),
  },
  {'role': 'user', 'content': text},
];

final _leadingThink = RegExp(r'^\s*<think\b[^>]*>[\s\S]*?</think>\s*');

/// Drops a leading reasoning block a thinking model may inline, and the
/// surrounding whitespace.
String cleanTranslationOutput(String raw) =>
    raw.replaceFirst(_leadingThink, '').trim();
