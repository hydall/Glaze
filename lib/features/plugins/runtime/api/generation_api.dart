import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../../core/llm/transport/call_attempt_outcome.dart';
import '../../../../core/llm/transport/chat_transport_request.dart';
import '../../../../core/llm/transport/llm_call_event.dart';
import '../../../../core/llm/transport/llm_capture_context.dart';
import '../../../../core/llm/transport/transport_factory.dart';
import '../../../../core/models/chat_message.dart';
import '../../../../core/state/db_provider.dart';
import '../../../../core/state/persona_resolution.dart';
import '../../../../core/utils/id_generator.dart';
import '../../../chat/chat_provider.dart';
import '../../../image_gen/image_gen_provider.dart';
import '../../../settings/api_list_provider.dart';
import '../../models/plugin_manifest.dart';
import '../plugin_api.dart';
import 'files_api.dart';

/// `glaze.generate(prompt, options)` (one-off text with the chat's
/// connection) and `glaze.images.generate(prompt, options)` (Glaze image
/// generation settings).
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
LlmCaptureContext _capture(PluginCall c, String stage) => LlmCaptureContext(
  stage: stage,
  sessionId: c.host.sessionId,
  agentId: c.plugin.id,
  callId: 'call:plugin:${generateId()}',
  attempt: 1,
);

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

Future<Object?> _generate(PluginCall c) async {
  final prompt = c.requireString(0, 'prompt');
  final options = c.mapArg(1);
  await c.ref.read(apiListProvider.future);
  var config = c.ref.read(activeApiConfigProvider);
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
    throw PluginApiError('generation_failed', '$e');
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
  final settings = await c.ref.read(imageGenSettingsProvider.future);
  final service = await c.ref
      .read(imageGenSettingsProvider.notifier)
      .getServiceAsync();
  await c.ref.read(apiListProvider.future);
  final api =
      c.ref.read(activeApiConfigProvider) ??
      c.ref.read(apiListProvider).value?.firstOrNull;
  final character = await c.ref
      .read(characterRepoProvider)
      .getById(c.host.charId);
  final persona = c.ref.read(
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
    final job = service.generateImage(
      settings: settings,
      prompt: prompt,
      llmEndpoint: api?.endpoint ?? '',
      llmApiKey: api?.apiKey ?? '',
      llmModel: api?.model ?? '',
      character: character,
      persona: persona,
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
    throw PluginApiError('generation_failed', '$e');
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
