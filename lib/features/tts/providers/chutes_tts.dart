import 'package:dio/dio.dart';

import '../models/tts_types.dart';
import '../services/tts_http.dart';
import 'tts_provider.dart';

/// Chutes' hosted Kokoro model. The voice list is fixed.
class ChutesTtsProvider extends TtsProvider {
  final TtsHttp http;
  const ChutesTtsProvider(this.http);

  static const _voices = <(String, String, String)>[
    ('af_alloy', 'Alloy (Female)', 'en-US'),
    ('af_aoede', 'Aoede (Female)', 'en-US'),
    ('af_bella', 'Bella (Female)', 'en-US'),
    ('af_heart', 'Heart (Female) - Default', 'en-US'),
    ('af_jessica', 'Jessica (Female)', 'en-US'),
    ('af_kore', 'Kore (Female)', 'en-US'),
    ('af_nicole', 'Nicole (Female)', 'en-US'),
    ('af_nova', 'Nova (Female)', 'en-US'),
    ('af_river', 'River (Female)', 'en-US'),
    ('af_sarah', 'Sarah (Female)', 'en-US'),
    ('af_sky', 'Sky (Female)', 'en-US'),
    ('am_adam', 'Adam (Male)', 'en-US'),
    ('am_echo', 'Echo (Male)', 'en-US'),
    ('am_eric', 'Eric (Male)', 'en-US'),
    ('am_fenrir', 'Fenrir (Male)', 'en-US'),
    ('am_liam', 'Liam (Male)', 'en-US'),
    ('am_michael', 'Michael (Male)', 'en-US'),
    ('am_onyx', 'Onyx (Male)', 'en-US'),
    ('am_puck', 'Puck (Male)', 'en-US'),
    ('am_santa', 'Santa (Male)', 'en-US'),
    ('bf_alice', 'Alice (British Female)', 'en-GB'),
    ('bf_emma', 'Emma (British Female)', 'en-GB'),
    ('bf_isabella', 'Isabella (British Female)', 'en-GB'),
    ('bf_lily', 'Lily (British Female)', 'en-GB'),
    ('bm_daniel', 'Daniel (British Male)', 'en-GB'),
    ('bm_fable', 'Fable (British Male)', 'en-GB'),
    ('bm_george', 'George (British Male)', 'en-GB'),
    ('bm_lewis', 'Lewis (British Male)', 'en-GB'),
    ('ef_dora', 'Dora (Spanish Female)', 'es-ES'),
    ('em_alex', 'Alex (Spanish Male)', 'es-ES'),
    ('em_santa', 'Santa (Spanish Male)', 'es-ES'),
    ('ff_siwis', 'Siwis (French Female)', 'fr-FR'),
    ('hf_alpha', 'Alpha (Hindi Female)', 'hi-IN'),
    ('hf_beta', 'Beta (Hindi Female)', 'hi-IN'),
    ('hm_omega', 'Omega (Hindi Male)', 'hi-IN'),
    ('hm_psi', 'Psi (Hindi Male)', 'hi-IN'),
    ('if_sara', 'Sara (Italian Female)', 'it-IT'),
    ('im_nicola', 'Nicola (Italian Male)', 'it-IT'),
    ('jf_alpha', 'Alpha (Japanese Female)', 'ja-JP'),
    ('jf_gongitsune', 'Gongitsune (Japanese Female)', 'ja-JP'),
    ('jf_nezumi', 'Nezumi (Japanese Female)', 'ja-JP'),
    ('jf_tebukuro', 'Tebukuro (Japanese Female)', 'ja-JP'),
    ('jm_kumo', 'Kumo (Japanese Male)', 'ja-JP'),
    ('pf_dora', 'Dora (Portuguese Female)', 'pt-PT'),
    ('pm_alex', 'Alex (Portuguese Male)', 'pt-PT'),
    ('pm_santa', 'Santa (Portuguese Male)', 'pt-PT'),
    ('zf_xiaobei', 'Xiaobei (Chinese Female)', 'zh-CN'),
    ('zf_xiaoni', 'Xiaoni (Chinese Female)', 'zh-CN'),
    ('zf_xiaoxiao', 'Xiaoxiao (Chinese Female)', 'zh-CN'),
    ('zf_xiaoyi', 'Xiaoyi (Chinese Female)', 'zh-CN'),
    ('zm_yunjian', 'Yunjian (Chinese Male)', 'zh-CN'),
    ('zm_yunxi', 'Yunxi (Chinese Male)', 'zh-CN'),
    ('zm_yunxia', 'Yunxia (Chinese Male)', 'zh-CN'),
    ('zm_yunyang', 'Yunyang (Chinese Male)', 'zh-CN'),
  ];

  @override
  String get id => 'chutes';

  @override
  String get displayName => 'Chutes';

  @override
  String get description => 'Kokoro on Chutes.';

  @override
  List<TtsField> get fields => const [
    TtsField.secret('apiKey', 'API key'),
    TtsField.number(
      'speed',
      'Speed',
      defaultValue: 1,
      min: 0.25,
      max: 3,
      step: 0.05,
    ),
  ];

  @override
  Future<List<TtsVoice>> fetchVoices(TtsProviderConfig config) async => [
    for (final (id, name, lang) in _voices)
      TtsVoice(name: name, voiceId: id, lang: lang),
  ];

  @override
  Future<void> checkReady(TtsProviderConfig config) async {
    config.require('apiKey');
  }

  @override
  Future<TtsAudio> generate(
    String text,
    String voiceId,
    TtsProviderConfig config, {
    String? speakerKey,
    CancelToken? cancelToken,
  }) => http.postForAudio(
    'https://chutes-kokoro.chutes.ai/speak',
    headers: {'Authorization': 'Bearer ${config.require('apiKey')}'},
    body: {
      'text': text,
      'voice': voiceId.isEmpty ? 'af_heart' : voiceId,
      'speed': config.number('speed'),
    },
    mime: 'audio/mpeg',
    cancelToken: cancelToken,
  );
}
