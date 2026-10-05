import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/state/shared_prefs_provider.dart';
import '../../core/utils/platform_paths.dart';
import 'models/tts_settings.dart';
import 'providers/tts_provider_registry.dart';
import 'services/tts_audio_cache.dart';
import 'services/tts_engine.dart';
import 'services/tts_http.dart';
import 'services/tts_player.dart';

final ttsSettingsProvider =
    AsyncNotifierProvider<TtsSettingsNotifier, TtsSettings>(
      TtsSettingsNotifier.new,
    );

class TtsSettingsNotifier extends AsyncNotifier<TtsSettings> {
  static const _key = 'gz_tts_settings';

  @override
  Future<TtsSettings> build() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final raw = prefs.getString(_key);
    if (raw == null) return const TtsSettings();
    try {
      return TtsSettingsCodec.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const TtsSettings();
    }
  }

  TtsSettings get _current => state.value ?? const TtsSettings();

  Future<void> save(TtsSettings settings) async {
    state = AsyncData(settings);
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setString(_key, jsonEncode(TtsSettingsCodec.toJson(settings)));
  }

  Future<void> change(TtsSettings Function(TtsSettings s) edit) =>
      save(edit(_current));
}

/// Provider list, shared by the settings screen and the engine.
final ttsRegistryProvider = Provider<TtsProviderRegistry>((ref) {
  return TtsProviderRegistry.standard(
    http: TtsHttp(),
    tempDir: () => p.join(cachedAppDataDir ?? '.', 'tts_session', 'tmp'),
  );
});

/// The app-wide TTS engine. One instance, so only one voice ever speaks.
final ttsEngineProvider = FutureProvider<TtsEngine>((ref) async {
  final root = await getAppDataDir();
  final cache = TtsAudioCache(root);
  await cache.load();
  final engine = TtsEngine(
    registry: ref.watch(ttsRegistryProvider),
    cache: cache,
    player: TtsPlayer(),
  );
  final settings = await ref.read(ttsSettingsProvider.future);
  engine.updateSettings(settings);
  ref.listen<AsyncValue<TtsSettings>>(ttsSettingsProvider, (_, next) {
    final value = next.value;
    if (value != null) engine.updateSettings(value);
  });
  ref.onDispose(() => unawaited(engine.dispose()));
  return engine;
});
