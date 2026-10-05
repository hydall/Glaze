import 'package:dio/dio.dart';

import '../models/tts_types.dart';
import '../services/tts_http.dart';
import 'tts_provider.dart';

/// Base for the two GPT-SoVITS local servers, which share the `/speakers`
/// listing but take different generation bodies.
abstract class _GptSovitsBase extends TtsProvider {
  final TtsHttp http;
  const _GptSovitsBase(this.http);

  @override
  bool get isLocal => true;

  @override
  Future<List<TtsVoice>> fetchVoices(TtsProviderConfig config) async =>
      voicesFromNames(
        await http.getJson('${config.str('endpoint')}/speakers'),
      );
}

/// The GPT-SoVITS SillyTavern adapter server.
class GptSovitsAdapterTtsProvider extends _GptSovitsBase {
  const GptSovitsAdapterTtsProvider(super.http);

  @override
  String get id => 'gpt_sovits_adapter';

  @override
  String get displayName => 'GPT-SoVITS Adapter';

  @override
  String get description => 'The GPT-SoVITS adapter server.';

  @override
  List<TtsField> get fields => const [
    TtsField.url('endpoint', 'Server', defaultValue: 'http://localhost:9881'),
    TtsField.text('textLang', 'Text language', defaultValue: 'ja'),
    TtsField.text('mediaType', 'Output format', defaultValue: 'wav'),
  ];

  @override
  Future<TtsAudio> generate(
    String text,
    String voiceId,
    TtsProviderConfig config, {
    String? speakerKey,
    CancelToken? cancelToken,
  }) => http.postForAudio(
    '${config.str('endpoint')}/',
    body: {
      'text': text,
      'target_voice': voiceId,
      'use_st_adapter': true,
      'text_lang': config.str('textLang'),
      'text_split_method': 'cut5',
      'batch_size': 1,
      'media_type': config.str('mediaType'),
      'streaming_mode': 'true',
    },
    mime: 'audio/${config.str('mediaType')}',
    cancelToken: cancelToken,
  );
}

/// GPT-SoVITS V2 (the community server).
class GptSovitsV2TtsProvider extends _GptSovitsBase {
  const GptSovitsV2TtsProvider(super.http);

  @override
  String get id => 'gpt_sovits_v2';

  @override
  String get displayName => 'GPT-SoVITS V2';

  @override
  String get description => 'A local GPT-SoVITS V2 server.';

  @override
  List<TtsField> get fields => const [
    TtsField.url('endpoint', 'Server', defaultValue: 'http://localhost:9880'),
    TtsField.text('refAudioDir', 'Reference folder', defaultValue: './参考音频/'),
    TtsField.text('textLang', 'Text language', defaultValue: 'zh'),
    TtsField.text('promptLang', 'Prompt language', defaultValue: 'zh'),
  ];

  @override
  Future<TtsAudio> generate(
    String text,
    String voiceId,
    TtsProviderConfig config, {
    String? speakerKey,
    CancelToken? cancelToken,
  }) => http.postForAudio(
    '${config.str('endpoint')}/',
    body: {
      'text': text,
      'prompt_text': voiceId.replaceAll(RegExp(r'\[.*?\]'), ''),
      'ref_audio_path': '${config.str('refAudioDir')}$voiceId.wav',
      'text_lang': config.str('textLang'),
      'prompt_lang': config.str('promptLang'),
      'text_split_method': 'cut5',
      'batch_size': 1,
      'media_type': 'ogg',
      'streaming_mode': 'true',
    },
    mime: 'audio/ogg',
    cancelToken: cancelToken,
  );
}
