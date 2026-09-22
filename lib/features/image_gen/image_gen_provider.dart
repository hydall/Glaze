import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/state/db_provider.dart';
import '../../../core/state/shared_prefs_provider.dart';
import 'image_gen_models.dart';
import 'image_gen_settings_codec.dart';
import 'services/image_gen_service.dart';

final imageGenSettingsProvider =
    AsyncNotifierProvider<ImageGenSettingsNotifier, ImageGenSettings>(
      ImageGenSettingsNotifier.new,
    );

class ImageGenSettingsNotifier extends AsyncNotifier<ImageGenSettings> {
  static const _key = 'gz_imggen_settings';

  @override
  Future<ImageGenSettings> build() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        return ImageGenSettingsCodec.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      } catch (_) {}
    }
    final migrated = await _migrateFromJsKeys(prefs);
    if (migrated != null) return migrated;
    return const ImageGenSettings();
  }

  Future<ImageGenSettings?> _migrateFromJsKeys(SharedPreferences prefs) async {
    final apiType = prefs.getString('gz_imggen_api_type');
    if (apiType == null) return null;
    final settings = ImageGenSettings(
      enabled: _safeBool(prefs, 'gz_imggen_enabled', false),
      apiType: ImageGenSettingsCodec.parseApiType(apiType),
      useSameEndpoint: _safeBool(prefs, 'gz_imggen_use_same', true),
      customEndpoint: prefs.getString('gz_imggen_endpoint') ?? '',
      customApiKey: prefs.getString('gz_imggen_api_key') ?? '',
      customModel: prefs.getString('gz_imggen_model') ?? '',
      openaiSize: prefs.getString('gz_imggen_image_size') ?? '1024x1024',
      openaiQuality: prefs.getString('gz_imggen_quality') ?? 'standard',
      geminiAspectRatio: prefs.getString('gz_imggen_aspect_ratio') ?? '1:1',
      geminiImageSize: prefs.getString('gz_imggen_gemini_image_size') ?? '1K',
      routmyApiKey: prefs.getString('gz_imggen_routmy_api_key') ?? '',
      routmyModel:
          prefs.getString('gz_imggen_routmy_model') ??
          'google/gemini-3.1-flash-image-preview',
      routmyAspectRatio:
          prefs.getString('gz_imggen_routmy_aspect_ratio') ?? '1:1',
      routmyImageSize: prefs.getString('gz_imggen_routmy_image_size') ?? '1K',
      routmyQuality: prefs.getString('gz_imggen_routmy_quality') ?? 'standard',
      naisteraApiKey: prefs.getString('gz_imggen_naistera_api_key') ?? '',
      naisteraModel: prefs.getString('gz_imggen_naistera_model') ?? 'grok',
      naisteraAspectRatio:
          prefs.getString('gz_imggen_naistera_aspect_ratio') ?? '1:1',
      sendCharAvatar:
          _safeBool(prefs, 'gz_imggen_routmy_send_char_avatar', false) ||
          _safeBool(prefs, 'gz_imggen_naistera_send_char_avatar', false),
      sendUserAvatar:
          _safeBool(prefs, 'gz_imggen_routmy_send_user_avatar', false) ||
          _safeBool(prefs, 'gz_imggen_naistera_send_user_avatar', false),
      imageContextEnabled: _safeBool(
        prefs,
        'gz_imggen_image_context_enabled',
        false,
      ),
      imageContextCount: _safeInt(prefs, 'gz_imggen_image_context_count', 1),
    );
    await prefs.setString(
      _key,
      jsonEncode(ImageGenSettingsCodec.toJson(settings)),
    );
    return settings;
  }

  bool _safeBool(SharedPreferences prefs, String key, bool defaultValue) {
    final raw = prefs.get(key);
    if (raw is bool) return raw;
    if (raw == 'true') return true;
    if (raw == 'false') return false;
    return defaultValue;
  }

  int _safeInt(SharedPreferences prefs, String key, int defaultValue) {
    final raw = prefs.get(key);
    if (raw is int) return raw;
    if (raw is String) return int.tryParse(raw) ?? defaultValue;
    return defaultValue;
  }

  Future<void> save(ImageGenSettings settings) async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setString(
      _key,
      jsonEncode(ImageGenSettingsCodec.toJson(settings)),
    );
    state = AsyncData(settings);
  }

  Future<void> updateEnabled(bool enabled) async {
    final s = state.value ?? const ImageGenSettings();
    await save(s.copyWith(enabled: enabled));
  }

  Future<void> updateApiType(ImageGenApiType apiType) async {
    final s = state.value ?? const ImageGenSettings();
    await save(s.copyWith(apiType: apiType));
  }

  ImageGenService? _service;
  Future<ImageGenService> getServiceAsync() async {
    if (_service != null) return _service!;
    final storage = await ref.read(imageStorageProvider.future);
    _service = ImageGenService(storage);
    return _service!;
  }

  ImageGenService? getService() {
    if (_service != null) return _service!;
    final storage = ref.read(imageStorageProvider).value;
    if (storage == null) return null;
    _service = ImageGenService(storage);
    return _service!;
  }
}
