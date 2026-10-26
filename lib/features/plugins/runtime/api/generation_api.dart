import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../../core/llm/transport/call_attempt_outcome.dart';
import '../../../../core/llm/transport/chat_transport_request.dart';
import '../../../../core/llm/transport/llm_call_event.dart';
import '../../../../core/llm/transport/llm_capture_context.dart';
import '../../../../core/llm/transport/transport_factory.dart';
import '../../../../core/models/api_config.dart';
import '../../../../core/models/chat_message.dart';
import '../../../../core/state/db_provider.dart';
import '../../../../core/state/persona_resolution.dart';
import '../../../../core/utils/error_format.dart';
import '../../../../core/utils/id_generator.dart';
import '../../../chat/chat_provider.dart';
import '../../../image_gen/image_gen_models.dart';
import '../../../image_gen/image_gen_provider.dart';
import '../../../settings/api_list_provider.dart';
import '../../models/plugin_manifest.dart';
import '../../models/plugin_settings_schema.dart';
import '../plugin_api.dart';
import 'files_api.dart';
import 'plugin_image_references.dart';

/// `glaze.generate(prompt, options)` (one-off text with the chat's
/// connection) and `glaze.images.generate(prompt, options)` (Glaze image
/// generation settings). `options.preset` names an `apiPreset` /
/// `imagePreset` setting of the plugin to run on the connection and model, or
/// the image service and style, the user picked for that feature instead.
Map<String, PluginMethod> generationApi() => {
  'generate': const PluginMethod(
    _generate,
    permission: PluginPermission.generate,
  ),
  'images.generate': const PluginMethod(
    _image,
    permission: PluginPermission.images,
    summary: 'plugins_consent_image',
  ),
};

/// What the Prompt Inspector's Requests tab shows a plugin's call under: its
/// chat, a stage of its own, and the plugin's id where an agent's name goes.
/// The run id is the call's own: an outcome without one is not stored.
LlmCaptureContext _capture(PluginCall c, String stage) {
  final id = 'call:plugin:${generateId()}';
  return LlmCaptureContext(
    stage: stage,
    sessionId: c.host.sessionId,
    agentId: c.plugin.id,
    pipelineRunId: id,
    callId: id,
    attempt: 1,
  );
}

/// Records how the call [_capture] describes ended, so the inspector has its
/// response or its error.
void _recordOutcome(
  LlmCaptureContext capture,
  DateTime started, {
  String? responseText,
  Object? error,
}) => unawaited(
  LlmCallEventCapture.record(
    LlmCallEvent.transport(
      context: capture,
      attempt: describeCallAttempt(
        attempt: 1,
        startedAtMs: started.millisecondsSinceEpoch,
        elapsedMs: DateTime.now().difference(started).inMilliseconds,
        error: error,
      ),
      responseText: responseText,
    ),
  ),
);

/// The preset `options.preset` names: a [type] setting the plugin declared,
/// with whatever the user picked for it. No `preset` is an unset one.
PluginPresetValue _preset(
  PluginCall c,
  Map<String, Object?> options,
  PluginSettingType type,
) {
  final key = options['preset'];
  if (key == null) return const PluginPresetValue();
  final declared =
      key is String &&
      c.plugin.manifest.settings.any((f) => f.key == key && f.type == type);
  if (!declared) {
    throw PluginApiError(
      'unknown_preset',
      'No "${type.name}" setting "$key" in the manifest',
    );
  }
  return PluginPresetValue.parse(c.plugin.config[key]);
}

/// The connection a plugin's call runs on: the one its [preset] binds, else
/// the chat's active one, with the preset's model override on top.
///
/// A bound connection that no longer exists falls back to the active one, so
/// a deleted connection never leaves the plugin unable to generate.
Future<ApiConfig?> _resolveConfig(
  PluginCall c,
  PluginPresetValue preset,
) async {
  final configs = await c.ref.read(apiListProvider.future);
  ApiConfig? config;
  if (preset.api.isNotEmpty) {
    config = configs.where((x) => x.id == preset.api).firstOrNull;
  }
  config ??= c.ref.read(activeApiConfigProvider);
  if (config != null && preset.model.isNotEmpty) {
    config = config.copyWith(model: preset.model);
  }
  return config;
}

Future<Object?> _generate(PluginCall c) async {
  final prompt = c.requireString(0, 'prompt');
  final options = c.mapArg(1);
  var config = await _resolveConfig(
    c,
    _preset(c, options, PluginSettingType.apiPreset),
  );
  if (config == null || config.model.isEmpty) {
    throw const PluginApiError('no_connection', 'No API connection is set up');
  }
  final settings = options['settings'];
  if (settings is Map) {
    final temperature = settings['temperature'];
    final maxTokens = settings['maxTokens'] ?? settings['maxCompletionTokens'];
    config = config.copyWith(
      temperature: temperature is num
          ? temperature.toDouble()
          : config.temperature,
      maxTokens: maxTokens is num ? maxTokens.toInt() : config.maxTokens,
    );
  }
  final messages = <Map<String, dynamic>>[
    if (options['system'] is String)
      {'role': 'system', 'content': options['system']},
  ];
  if (options['context'] == true) {
    // The chat goes to the model and its reply to the plugin.
    await c.require(PluginPermission.messages);
    final history =
        c.ref.read(chatProvider(c.host.charId)).value?.session?.messages ??
        const <ChatMessage>[];
    final visible = history
        .where(
          (m) => !m.isHidden && (m.role == 'user' || m.role == 'assistant'),
        )
        .toList();
    for (final m in visible.skip(
      visible.length > 40 ? visible.length - 40 : 0,
    )) {
      messages.add({'role': m.role, 'content': m.content});
    }
  }
  messages.add({'role': 'user', 'content': prompt});

  final cancelToken = CancelToken();
  final completer = Completer<String>();
  final capture = _capture(c, 'plugin.generate');
  final started = DateTime.now();
  unawaited(
    pickChatTransport(config.protocol).stream(
      request: ChatTransportRequest.fromApiConfig(
        config,
        messages: messages,
        stream: false,
        sessionId: c.host.sessionId,
        captureContext: capture,
      ),
      cancelToken: cancelToken,
      onComplete: (text, _, {rawResponseJson}) {
        if (!completer.isCompleted) completer.complete(text);
      },
      onError: (error) {
        if (!completer.isCompleted) completer.completeError(error);
      },
    ),
  );
  final timeoutMs = options['timeout'];
  final limit = timeoutMs is num && timeoutMs > 0
      ? Duration(milliseconds: timeoutMs.toInt())
      : const Duration(minutes: 5);
  try {
    final text = await completer.future.timeout(limit);
    _recordOutcome(capture, started, responseText: text);
    return text;
  } on TimeoutException catch (e) {
    cancelToken.cancel('glaze.generate timed out');
    _recordOutcome(capture, started, error: e);
    throw const PluginApiError('timeout', 'Generation timed out');
  } catch (e) {
    _recordOutcome(capture, started, error: e);
    if (e is PluginApiError) rethrow;
    throw PluginApiError('generation_failed', formatError(e));
  }
}

String _imageMime(Uint8List b) {
  if (b.length > 3 && b[0] == 0x89 && b[1] == 0x50) return 'image/png';
  if (b.length > 2 && b[0] == 0xFF && b[1] == 0xD8) return 'image/jpeg';
  if (b.length > 11 && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42) {
    return 'image/webp';
  }
  if (b.length > 3 && b[0] == 0x47 && b[1] == 0x49) return 'image/gif';
  return 'image/png';
}

Future<Object?> _image(PluginCall c) async {
  final prompt = c.requireString(0, 'prompt');
  final options = c.mapArg(1);
  final preset = _preset(c, options, PluginSettingType.imagePreset);
  var settings = await c.ref.read(imageGenSettingsProvider.future);
  // The preset's image service; an unknown name (a newer Glaze's) follows
  // the image settings.
  final provider = ImageGenApiType.values
      .where((t) => t.name == preset.provider)
      .firstOrNull;
  if (provider != null) settings = settings.copyWith(apiType: provider);
  // The preset's style: follow the image settings (empty), force none, or
  // draw in a named one of the library.
  if (preset.style == kPluginNoImageStyle) {
    settings = settings.copyWith(activeStyleId: '');
  } else if (preset.style.isNotEmpty) {
    settings = settings.copyWith(activeStyleId: preset.style);
  }
  final service = await c.ref
      .read(imageGenSettingsProvider.notifier)
      .getServiceAsync();
  // Services that draw through the chat's endpoint use the chat's connection.
  final api = await _resolveConfig(c, const PluginPresetValue());
  // `character: false` / `persona: false`: that person is not in the picture,
  // so neither their avatar nor their appearance goes along.
  final character = options['character'] == false
      ? null
      : await c.ref.read(characterRepoProvider).getById(c.host.charId);
  final persona = options['persona'] == false
      ? null
      : c.ref.read(
          effectivePersonaForChatProvider((
            charId: c.host.charId,
            sessionId: c.host.sessionId,
          )),
        );
  final cancelToken = CancelToken();
  final capture = _capture(c, 'image.plugin');
  final started = DateTime.now();
  final Uint8List bytes;
  try {
    // Tavo's `image.generate` spells them `referenceImages`; the older
    // ImageGen bridge used `characters`. Both carry names and URLs.
    final pluginReferences = await resolvePluginImageReferences(
      c,
      options['referenceImages'] ?? options['characters'],
    );
    final job = service.generateImage(
      settings: settings,
      prompt: prompt,
      llmEndpoint: api?.endpoint ?? '',
      llmApiKey: api?.apiKey ?? '',
      llmModel: api?.model ?? '',
      character: character,
      persona: persona,
      pluginReferences: pluginReferences,
      instructionAspectRatio: options['aspectRatio']?.toString(),
      instructionImageSize: options['size']?.toString(),
      cancelToken: cancelToken,
      captureContext: capture,
    );
    final timeoutMs = options['timeout'];
    bytes = timeoutMs is num && timeoutMs > 0
        ? await job.timeout(Duration(milliseconds: timeoutMs.toInt()))
        : await job;
  } on TimeoutException catch (e) {
    cancelToken.cancel('glaze.images.generate timed out');
    _recordOutcome(capture, started, error: e);
    throw const PluginApiError('timeout', 'Image generation timed out');
  } catch (e) {
    _recordOutcome(capture, started, error: e);
    // The provider's own message, not a Dio dump.
    throw PluginApiError('generation_failed', formatError(e));
  }
  final mime = _imageMime(bytes);
  _recordOutcome(
    capture,
    started,
    responseText: '$mime, ${(bytes.length / 1024).ceil()} KB',
  );
  final saveAs = options['saveAs'];
  if (saveAs is String && saveAs.isNotEmpty) {
    await c.require(PluginPermission.files);
    final info = await savePluginFile(
      c,
      saveAs,
      bytes,
      scope: options['scope'] == 'global' ? 'global' : 'chat',
    );
    return info['path'];
  }
  return 'data:$mime;base64,${base64Encode(bytes)}';
}
