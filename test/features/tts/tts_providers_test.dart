import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/tts/models/tts_settings.dart';
import 'package:glaze_flutter/features/tts/models/tts_types.dart';
import 'package:glaze_flutter/features/tts/providers/elevenlabs_tts.dart';
import 'package:glaze_flutter/features/tts/providers/fish_audio_tts.dart';
import 'package:glaze_flutter/features/tts/providers/openai_compatible_tts.dart';
import 'package:glaze_flutter/features/tts/providers/openai_tts.dart';
import 'package:glaze_flutter/features/tts/providers/tts_provider.dart';
import 'package:glaze_flutter/features/tts/services/tts_audio_analysis.dart';
import 'package:glaze_flutter/features/tts/services/tts_http.dart';
import 'package:glaze_flutter/features/tts/services/tts_planner.dart';
import 'package:glaze_flutter/features/tts/services/tts_text_preparer.dart';
import 'package:glaze_flutter/features/tts/services/tts_voice_resolver.dart';

/// Records every request and answers with a short WAV.
class _RecordingAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  Object? Function(RequestOptions)? json;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final body = json?.call(options);
    if (body != null) {
      return ResponseBody.fromString(jsonEncode(body), 200, headers: {
        'content-type': ['application/json'],
      });
    }
    return ResponseBody.fromBytes(
      TtsAudioAnalysis.pcm16ToWav(Uint8List(800), sampleRate: 8000),
      200,
      headers: {
        'content-type': ['application/octet-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _RecordingAdapter adapter;
  late TtsHttp http;

  setUp(() {
    adapter = _RecordingAdapter();
    http = TtsHttp(Dio()..httpClientAdapter = adapter);
  });

  Map<String, dynamic> body(RequestOptions r) =>
      Map<String, dynamic>.from(r.data as Map);

  test('OpenAI sends model, voice, WAV and per-speaker instructions', () async {
    final provider = OpenAiTtsProvider(http);
    final config = provider.configFrom({
      'apiKey': 'sk-1',
      'instructions:char:7': 'Whisper',
    });
    final audio = await provider.generate('Hi', 'nova', config, speakerKey: 'char:7');
    final r = adapter.requests.single;
    expect(r.uri.toString(), 'https://api.openai.com/v1/audio/speech');
    expect(r.headers['Authorization'], 'Bearer sk-1');
    expect(body(r), {
      'model': 'gpt-4o-mini-tts',
      'input': 'Hi',
      'voice': 'nova',
      'speed': 1.0,
      'response_format': 'wav',
      'instructions': 'Whisper',
    });
    // The octet-stream label is corrected from the bytes.
    expect(audio.mime, 'audio/wav');
  });

  test('OpenAI without a key reports what is missing', () async {
    final provider = OpenAiTtsProvider(http);
    expect(
      () => provider.generate('Hi', 'nova', provider.configFrom({})),
      throwsA(isA<TtsNotConfigured>()),
    );
  });

  test('OpenAI-compatible posts to the configured endpoint', () async {
    final provider = OpenAiCompatibleTtsProvider(http);
    final config = provider.configFrom({
      'endpoint': 'http://localhost:8880/v1/audio/speech',
      'voices': 'Bella:af_bella, am_adam',
    });
    final voices = await provider.fetchVoices(config);
    expect(voices.map((v) => (v.name, v.voiceId)), [
      ('Bella', 'af_bella'),
      ('am_adam', 'am_adam'),
    ]);
    await provider.generate('Hi', 'af_bella', config);
    final r = adapter.requests.single;
    expect(r.uri.toString(), 'http://localhost:8880/v1/audio/speech');
    expect(r.headers.containsKey('Authorization'), isFalse);
    expect(body(r)['voice'], 'af_bella');
    expect(body(r)['response_format'], 'mp3');
  });

  test('ElevenLabs uses xi-api-key, voice settings and PCM framing', () async {
    final provider = ElevenLabsTtsProvider(http);
    final config = provider.configFrom({'apiKey': 'el', 'format': 'pcm_24000'});
    final audio = await provider.generate('Hi', 'v123', config);
    final r = adapter.requests.single;
    expect(r.uri.path, '/v1/text-to-speech/v123');
    expect(r.uri.queryParameters['output_format'], 'pcm_24000');
    expect(r.headers['xi-api-key'], 'el');
    expect(body(r)['model_id'], 'eleven_multilingual_v2');
    expect((body(r)['voice_settings'] as Map)['stability'], 0.75);
    expect(audio.mime, 'audio/pcm;rate=24000');
  });

  test('ElevenLabs reads the voice list', () async {
    adapter.json = (_) => {
      'voices': [
        {
          'voice_id': 'abc',
          'name': 'Rachel',
          'preview_url': 'https://x/p.mp3',
          'labels': {'language': 'en'},
        },
      ],
    };
    final provider = ElevenLabsTtsProvider(http);
    final voices = await provider.fetchVoices(provider.configFrom({'apiKey': 'k'}));
    expect(voices.single.name, 'Rachel');
    expect(voices.single.voiceId, 'abc');
  });

  group('Fish Audio', () {
    test('sends reference id, model header and WAV request', () async {
      final provider = FishAudioTtsProvider(http);
      final config = provider.configFrom({'apiKey': 'f', 'voices': 'Mita:ref1'});
      await provider.generate('Hello there', 'ref1', config);
      final r = adapter.requests.single;
      expect(r.uri.toString(), 'https://api.fish.audio/v1/tts');
      expect(r.headers['Authorization'], 'Bearer f');
      expect(r.headers['model'], 's2.1-pro');
      expect(body(r), {
        'text': 'Hello there',
        'reference_id': 'ref1',
        'format': 'wav',
        'sample_rate': 44100,
        'latency': 'normal',
      });
    });

    test('switches voice by the language of the text', () async {
      final provider = FishAudioTtsProvider(http);
      final config = provider.configFrom({
        'apiKey': 'f',
        'languageVoices': 'ru:ru_voice, en:en_voice',
      });
      await provider.generate('Привет, как дела?', 'base', config);
      expect(body(adapter.requests.single)['reference_id'], 'ru_voice');
      expect(FishAudioTtsProvider.detectLanguage('こんにちは世界'), 'ja');
      expect(FishAudioTtsProvider.detectLanguage('Hello'), 'en');
    });

    test('lists manual voices before the account models', () async {
      adapter.json = (_) => {
        'items': [
          {'_id': 'own1', 'title': 'My voice', 'languages': ['en']},
        ],
      };
      final provider = FishAudioTtsProvider(http);
      final voices = await provider.fetchVoices(
        provider.configFrom({'apiKey': 'f', 'voices': 'Mita:ref1'}),
      );
      expect(voices.map((v) => v.voiceId), ['ref1', 'own1']);
      expect(adapter.requests.single.uri.queryParameters['self'], 'true');
    });
  });

  group('voice map', () {
    final provider = OpenAiCompatibleTtsProvider(TtsHttp());
    final config = provider.configFrom({'voices': 'A:a, B:b, C:c'});
    final resolver = TtsVoiceResolver(TtsVoiceCatalog());

    Future<String?> pick(Map<String, String> map, {bool multi = false, TtsSegmentType type = TtsSegmentType.other}) async {
      final choice = await resolver.resolve(
        provider: provider,
        config: config,
        voiceMap: map,
        speakerKey: 'char:1',
        type: type,
        multiVoice: multi,
      );
      return choice is TtsVoiceResolved ? choice.voice.voiceId : null;
    }

    test('specific entry wins', () async {
      expect(await pick({'char:1': 'B', ttsDefaultVoiceKey: 'C'}), 'b');
    });

    test('missing or default entry uses the default voice', () async {
      expect(await pick({ttsDefaultVoiceKey: 'C'}), 'c');
      expect(await pick({'char:1': ttsDefaultVoiceMarker, ttsDefaultVoiceKey: 'C'}), 'c');
    });

    test('nothing set falls back to the first voice', () async {
      expect(await pick({}), 'a');
    });

    test('disabled silences the speaker', () async {
      expect(await pick({'char:1': ttsDisabledVoiceMarker}), isNull);
    });

    test('multi-voice slots inherit the speaker voice', () async {
      final map = {'char:1': 'B', 'char:1#dialogue': 'C'};
      expect(await pick(map, multi: true, type: TtsSegmentType.dialogue), 'c');
      expect(await pick(map, multi: true, type: TtsSegmentType.action), 'b');
    });
  });

  test('planner keys change when the message is edited', () async {
    final provider = OpenAiCompatibleTtsProvider(http);
    final planner = TtsPlanner(TtsVoiceResolver(TtsVoiceCatalog()));
    final settings = const TtsSettings(providerId: 'openai_compatible');
    Future<String> sig(String text) async => (await planner.plan(
          TtsMessageInput(messageId: 'm', text: text, speakerKey: 'char:1'),
          settings,
          provider,
        ))!
        .signature;
    expect(await sig('Hello'), await sig('Hello'));
    expect(await sig('Hello'), isNot(await sig('Hello again')));
  });

  test('settings survive a JSON round trip', () {
    final s = const TtsSettings(
      enabled: true,
      providerId: 'fish',
      multiVoice: true,
      providerSettings: {
        'fish': {'apiKey': 'x', 'speed': 1.2},
      },
      voiceMaps: {
        'fish': {'char:1': 'Mita'},
      },
    );
    final decoded = TtsSettingsCodec.fromJson(
      jsonDecode(jsonEncode(TtsSettingsCodec.toJson(s))) as Map<String, dynamic>,
    );
    expect(decoded, s);
  });

  test('parseVoiceList keeps URL ids intact', () {
    expect(parseVoiceList('http://x/voice.wav').single.voiceId, 'http://x/voice.wav');
  });
}
