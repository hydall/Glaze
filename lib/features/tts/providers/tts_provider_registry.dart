import '../services/tts_http.dart';
import 'elevenlabs_tts.dart';
import 'fish_audio_tts.dart';
import 'openai_compatible_tts.dart';
import 'openai_tts.dart';
import 'system_tts.dart';
import 'tts_provider.dart';

/// Every TTS provider, by id. The order is the order of the picker.
class TtsProviderRegistry {
  final List<TtsProvider> providers;

  TtsProviderRegistry(this.providers);

  factory TtsProviderRegistry.standard({
    required TtsHttp http,
    required String Function() tempDir,
  }) => TtsProviderRegistry([
    ElevenLabsTtsProvider(http),
    FishAudioTtsProvider(http),
    OpenAiTtsProvider(http),
    OpenAiCompatibleTtsProvider(http),
    SystemTtsProvider(tempDir: tempDir),
  ]);

  TtsProvider? byId(String id) {
    for (final p in providers) {
      if (p.id == id) return p;
    }
    return null;
  }
}
