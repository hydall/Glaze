import '../services/tts_http.dart';
import 'alltalk_tts.dart';
import 'azure_tts.dart';
import 'chatterbox_tts.dart';
import 'chutes_tts.dart';
import 'cosyvoice_tts.dart';
import 'electronhub_tts.dart';
import 'elevenlabs_tts.dart';
import 'fish_audio_tts.dart';
import 'google_native_tts.dart';
import 'google_translate_tts.dart';
import 'gpt_sovits_tts.dart';
import 'gsvi_tts.dart';
import 'minimax_tts.dart';
import 'novelai_tts.dart';
import 'openai_compatible_tts.dart';
import 'openai_tts.dart';
import 'pollinations_tts.dart';
import 'sbvits2_tts.dart';
import 'silero_tts.dart';
import 'system_tts.dart';
import 'tts_provider.dart';
import 'tts_webui_tts.dart';
import 'vits_tts.dart';
import 'xtts_tts.dart';

/// Every TTS provider, by id. The order is the order of the picker: cloud
/// services first, then local servers, then the system voices.
class TtsProviderRegistry {
  final List<TtsProvider> providers;

  TtsProviderRegistry(this.providers);

  factory TtsProviderRegistry.standard({
    required TtsHttp http,
    required String Function() tempDir,
  }) => TtsProviderRegistry([
    // Cloud
    ElevenLabsTtsProvider(http),
    FishAudioTtsProvider(http),
    OpenAiTtsProvider(http),
    OpenAiCompatibleTtsProvider(http),
    AzureTtsProvider(http),
    GoogleNativeTtsProvider(http),
    GoogleTranslateTtsProvider(http),
    MiniMaxTtsProvider(http),
    NovelAiTtsProvider(http),
    PollinationsTtsProvider(http),
    ElectronHubTtsProvider(http),
    ChutesTtsProvider(http),
    // Local servers
    AllTalkTtsProvider(http),
    ChatterboxTtsProvider(http),
    CosyVoiceTtsProvider(http),
    GptSovitsAdapterTtsProvider(http),
    GptSovitsV2TtsProvider(http),
    GsviTtsProvider(http),
    Sbvits2TtsProvider(http),
    SileroTtsProvider(http),
    TtsWebuiProvider(http),
    VitsTtsProvider(http),
    XttsTtsProvider(http),
    // Operating system
    SystemTtsProvider(tempDir: tempDir),
  ]);

  TtsProvider? byId(String id) {
    for (final p in providers) {
      if (p.id == id) return p;
    }
    return null;
  }
}
