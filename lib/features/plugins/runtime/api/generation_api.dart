import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../../core/llm/transport/chat_transport_request.dart';
import '../../../../core/llm/transport/transport_factory.dart';
import '../../../../core/models/chat_message.dart';
import '../../../../core/state/db_provider.dart';
import '../../../../core/state/persona_resolution.dart';
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
    consent: PluginConsent.images,
    summary: 'plugins_consent_image',
  ),
};

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
  unawaited(
    pickChatTransport(config.protocol).stream(
      request: ChatTransportRequest.fromApiConfig(
        config,
        messages: messages,
        stream: false,
        sessionId: c.host.sessionId,
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
    return await completer.future.timeout(limit);
  } on TimeoutException {
    cancelToken.cancel('glaze.generate timed out');
    throw const PluginApiError('timeout', 'Generation timed out');
  } catch (e) {
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
    );
    final timeoutMs = options['timeout'];
    bytes = timeoutMs is num && timeoutMs > 0
        ? await job.timeout(Duration(milliseconds: timeoutMs.toInt()))
        : await job;
  } on TimeoutException {
    cancelToken.cancel('glaze.images.generate timed out');
    throw const PluginApiError('timeout', 'Image generation timed out');
  } catch (e) {
    throw PluginApiError('generation_failed', '$e');
  }
  final mime = _imageMime(bytes);
  final saveAs = options['saveAs'];
  if (saveAs is String && saveAs.isNotEmpty) {
    if (!c.plugin.allows(PluginPermission.files)) {
      throw const PluginApiError(
        'permission_denied',
        'saveAs needs the "files" permission',
      );
    }
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
