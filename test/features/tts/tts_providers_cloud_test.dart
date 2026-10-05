import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/tts/models/tts_types.dart';
import 'package:glaze_flutter/features/tts/providers/alltalk_tts.dart';
import 'package:glaze_flutter/features/tts/providers/azure_tts.dart';
import 'package:glaze_flutter/features/tts/providers/chutes_tts.dart';
import 'package:glaze_flutter/features/tts/providers/electronhub_tts.dart';
import 'package:glaze_flutter/features/tts/providers/google_native_tts.dart';
import 'package:glaze_flutter/features/tts/providers/gpt_sovits_tts.dart';
import 'package:glaze_flutter/features/tts/providers/minimax_tts.dart';
import 'package:glaze_flutter/features/tts/providers/pollinations_tts.dart';
import 'package:glaze_flutter/features/tts/providers/silero_tts.dart';
import 'package:glaze_flutter/features/tts/services/tts_audio_analysis.dart';
import 'package:glaze_flutter/features/tts/services/tts_http.dart';

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  Object? Function(RequestOptions)? json;
  int bytesStatus = 200;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final body = json?.call(options);
    if (body != null) {
      return ResponseBody.fromString(
        jsonEncode(body),
        200,
        headers: {
          'content-type': ['application/json'],
        },
      );
    }
    return ResponseBody.fromBytes(
      TtsAudioAnalysis.pcm16ToWav(Uint8List(800), sampleRate: 8000),
      bytesStatus,
      headers: {
        'content-type': ['application/octet-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _Adapter adapter;
  late TtsHttp http;

  setUp(() {
    adapter = _Adapter();
    http = TtsHttp(Dio()..httpClientAdapter = adapter);
  });

  Map<String, dynamic> body(RequestOptions r) =>
      Map<String, dynamic>.from(r.data as Map);

  test('Azure lists voices and sends SSML', () async {
    adapter.json = (r) => r.uri.path.endsWith('/list')
        ? [
            {'ShortName': 'en-US-AriaNeural', 'Locale': 'en-US'},
            {'ShortName': 'ru-RU-SvetlanaNeural', 'Locale': 'ru-RU'},
          ]
        : null;
    final provider = AzureTtsProvider(http);
    final config = provider.configFrom({'apiKey': 'k', 'region': 'westus'});
    final voices = await provider.fetchVoices(config);
    expect(voices.map((v) => v.voiceId), [
      'en-US-AriaNeural',
      'ru-RU-SvetlanaNeural',
    ]);
    adapter.requests.clear();
    await provider.generate('Hi & bye', 'en-US-AriaNeural', config);
    final r = adapter.requests.single;
    expect(r.uri.host, 'westus.tts.speech.microsoft.com');
    expect(r.headers['Ocp-Apim-Subscription-Key'], 'k');
    expect(r.headers['Content-Type'], 'application/ssml+xml');
    expect(r.data, contains('Hi &amp; bye'));
    expect(r.data, contains("name='en-US-AriaNeural'"));
  });

  test('MiniMax decodes the hex audio payload', () async {
    final pcm = TtsAudioAnalysis.pcm16ToWav(
      Uint8List.fromList([1, 0, 2, 0]),
      sampleRate: 8000,
    );
    final hex = pcm.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    adapter.json = (_) => {
      'base_resp': {'status_code': 0},
      'data': {'audio': hex},
    };
    final provider = MiniMaxTtsProvider(http);
    final audio = await provider.generate(
      'Hi',
      'voice1',
      provider.configFrom({'apiKey': 'k'}),
    );
    expect(audio.bytes, pcm);
    expect(adapter.requests.single.uri.path, '/v1/t2a_v2');
  });

  test('MiniMax surfaces an API error', () async {
    adapter.json = (_) => {
      'base_resp': {'status_code': 1004, 'status_msg': 'bad key'},
    };
    final provider = MiniMaxTtsProvider(http);
    expect(
      () => provider.generate('Hi', 'v', provider.configFrom({'apiKey': 'k'})),
      throwsA(isA<TtsException>()),
    );
  });

  test('Electron Hub posts to its speech endpoint', () async {
    final provider = ElectronHubTtsProvider(http);
    await provider.generate(
      'Hi',
      'nova',
      provider.configFrom({'apiKey': 'e', 'model': 'gpt-4o-mini-tts', 'instructions': 'calm'}),
    );
    final r = adapter.requests.single;
    expect(r.uri.toString(), 'https://api.electronhub.ai/v1/audio/speech');
    expect(body(r)['instructions'], 'calm');
    expect(body(r)['voice'], 'nova');
  });

  test('Chutes posts text, voice and speed', () async {
    final provider = ChutesTtsProvider(http);
    await provider.generate('Hi', 'af_bella', provider.configFrom({'apiKey': 'c'}));
    final r = adapter.requests.single;
    expect(r.uri.toString(), 'https://chutes-kokoro.chutes.ai/speak');
    expect(body(r), {'text': 'Hi', 'voice': 'af_bella', 'speed': 1.0});
  });

  test('Pollinations reads voices and audio', () async {
    adapter.json = (r) => r.uri.path.contains('models')
        ? [
            {
              'name': 'openai-audio',
              'voices': ['alloy', 'nova'],
            },
          ]
        : {
            'choices': [
              {
                'message': {
                  'audio': {'data': base64Encode([9, 8, 7])},
                },
              },
            ],
          };
    final provider = PollinationsTtsProvider(http);
    final config = provider.configFrom({'apiKey': 'p'});
    expect((await provider.fetchVoices(config)).map((v) => v.voiceId), [
      'alloy',
      'nova',
    ]);
    final audio = await provider.generate('Hi', 'nova', config);
    expect(audio.bytes, [9, 8, 7]);
  });

  test('Google Gemini wraps PCM in a WAV', () async {
    adapter.json = (_) => {
      'candidates': [
        {
          'content': {
            'parts': [
              {
                'inlineData': {
                  'mimeType': 'audio/l16;rate=24000',
                  'data': base64Encode([0, 0, 10, 0]),
                },
              },
            ],
          },
        },
      ],
    };
    final provider = GoogleNativeTtsProvider(http);
    final audio = await provider.generate(
      'Hi',
      'Puck',
      provider.configFrom({'apiKey': 'g'}),
    );
    expect(audio.mime, 'audio/wav');
    expect(String.fromCharCodes(audio.bytes.sublist(0, 4)), 'RIFF');
  });

  test('AllTalk posts a form and downloads the file URL', () async {
    adapter.json = (r) => r.uri.path.endsWith('/tts-generate')
        ? {'output_file_url': '/outputs/glaze.wav'}
        : null;
    final provider = AllTalkTtsProvider(http);
    await provider.generate(
      'Hi',
      'female_01.wav',
      provider.configFrom({'endpoint': 'http://at:7851'}),
    );
    expect(adapter.requests.length, 2);
    expect(
      adapter.requests.first.headers['Content-Type'],
      contains('application/x-www-form-urlencoded'),
    );
    expect(adapter.requests.first.data, contains('character_voice_gen'));
    expect(
      adapter.requests.last.uri.toString(),
      'http://at:7851/outputs/glaze.wav',
    );
  });

  test('Silero lists speakers and posts a generate request', () async {
    adapter.json = (r) =>
        r.uri.path.endsWith('/speakers') ? ['eugene', 'aidar'] : null;
    final provider = SileroTtsProvider(http);
    final config = provider.configFrom({'endpoint': 'http://s:8001'});
    expect((await provider.fetchVoices(config)).map((v) => v.voiceId), [
      'eugene',
      'aidar',
    ]);
    adapter.requests.clear();
    await provider.generate('Hi', 'aidar', config);
    final r = adapter.requests.single;
    expect(r.uri.path, '/generate');
    expect(body(r)['speaker'], 'aidar');
  });

  test('GPT-SoVITS adapter sends the adapter body', () async {
    final provider = GptSovitsAdapterTtsProvider(http);
    await provider.generate(
      'Hi',
      'voiceA',
      provider.configFrom({'endpoint': 'http://g:9881'}),
    );
    final r = adapter.requests.single;
    expect(r.uri.toString(), 'http://g:9881/');
    expect(body(r)['target_voice'], 'voiceA');
    expect(body(r)['use_st_adapter'], isTrue);
  });

  test('GPT-SoVITS V2 builds the reference path', () async {
    final provider = GptSovitsV2TtsProvider(http);
    await provider.generate(
      'Hi',
      'voiceA[EN]',
      provider.configFrom({'endpoint': 'http://g:9880'}),
    );
    final r = adapter.requests.single;
    expect(body(r)['ref_audio_path'], './参考音频/voiceA[EN].wav');
    expect(body(r)['prompt_text'], 'voiceA');
  });
}
