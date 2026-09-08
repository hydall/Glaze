import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/state/db_provider.dart';
import '../../../core/state/shared_prefs_provider.dart';
import 'image_gen_models.dart';
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
        return _fromJson(jsonDecode(raw) as Map<String, dynamic>);
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
      apiType: _parseApiType(apiType),
      useSameEndpoint: _safeBool(prefs, 'gz_imggen_use_same', true),
      customEndpoint: prefs.getString('gz_imggen_endpoint') ?? '',
      customApiKey: prefs.getString('gz_imggen_api_key') ?? '',
      customModel: prefs.getString('gz_imggen_model') ?? '',
      openaiSize: prefs.getString('gz_imggen_image_size') ?? '1024x1024',
      openaiQuality: prefs.getString('gz_imggen_quality') ?? 'standard',
      geminiAspectRatio: prefs.getString('gz_imggen_aspect_ratio') ?? '1:1',
      geminiImageSize: prefs.getString('gz_imggen_gemini_image_size') ?? '1K',
      routmyApiKey: prefs.getString('gz_imggen_routmy_api_key') ?? '',
      routmyModel: prefs.getString('gz_imggen_routmy_model') ?? 'google/gemini-3.1-flash-image-preview',
      routmyAspectRatio: prefs.getString('gz_imggen_routmy_aspect_ratio') ?? '1:1',
      routmyImageSize: prefs.getString('gz_imggen_routmy_image_size') ?? '1K',
      routmyQuality: prefs.getString('gz_imggen_routmy_quality') ?? 'standard',
      routmySendCharAvatar: _safeBool(prefs, 'gz_imggen_routmy_send_char_avatar', false),
      routmySendUserAvatar: _safeBool(prefs, 'gz_imggen_routmy_send_user_avatar', false),
      naisteraApiKey: prefs.getString('gz_imggen_naistera_api_key') ?? '',
      naisteraModel: prefs.getString('gz_imggen_naistera_model') ?? 'grok',
      naisteraAspectRatio: prefs.getString('gz_imggen_naistera_aspect_ratio') ?? '1:1',
      naisteraSendCharAvatar: _safeBool(prefs, 'gz_imggen_naistera_send_char_avatar', false),
      naisteraSendUserAvatar: _safeBool(prefs, 'gz_imggen_naistera_send_user_avatar', false),
      ruRoutmyApiKey: prefs.getString('gz_imggen_ru_routmy_api_key') ?? '',
      imageContextEnabled: _safeBool(prefs, 'gz_imggen_image_context_enabled', false),
      imageContextCount: _safeInt(prefs, 'gz_imggen_image_context_count', 1),
    );
    await prefs.setString(_key, jsonEncode(_toJson(settings)));
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
    await prefs.setString(_key, jsonEncode(_toJson(settings)));
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

  Map<String, dynamic> _toJson(ImageGenSettings s) => {
    'enabled': s.enabled,
    'apiType': s.apiType.name,
    'useSameEndpoint': s.useSameEndpoint,
    'customEndpoint': s.customEndpoint,
    'customApiKey': s.customApiKey,
    'customModel': s.customModel,
    'openaiSize': s.openaiSize,
    'openaiQuality': s.openaiQuality,
    'geminiAspectRatio': s.geminiAspectRatio,
    'geminiImageSize': s.geminiImageSize,
    'naisteraApiKey': s.naisteraApiKey,
    'naisteraModel': s.naisteraModel,
    'naisteraAspectRatio': s.naisteraAspectRatio,
    'naisteraSendCharAvatar': s.naisteraSendCharAvatar,
    'naisteraSendUserAvatar': s.naisteraSendUserAvatar,
    'routmyApiKey': s.routmyApiKey,
    'routmyModel': s.routmyModel,
    'routmyAspectRatio': s.routmyAspectRatio,
    'routmyImageSize': s.routmyImageSize,
    'routmyQuality': s.routmyQuality,
    'routmySendCharAvatar': s.routmySendCharAvatar,
    'routmySendUserAvatar': s.routmySendUserAvatar,
    'imageContextEnabled': s.imageContextEnabled,
    'imageContextCount': s.imageContextCount,
    'additionalReferences': s.additionalReferences.map((r) => {
      'name': r.name, 'imageData': r.imageData, 'matchMode': r.matchMode,
    }).toList(),
    'routmyAdditionalRefs': s.routmyAdditionalRefs.map((r) => {
      'name': r.name, 'imageData': r.imageData, 'matchMode': r.matchMode,
    }).toList(),
    'ruRoutmyApiKey': s.ruRoutmyApiKey,
    'ruRoutmyModel': s.ruRoutmyModel,
    'ruRoutmyAspectRatio': s.ruRoutmyAspectRatio,
    'ruRoutmyImageSize': s.ruRoutmyImageSize,
    'ruRoutmyQuality': s.ruRoutmyQuality,
    'ruRoutmySendCharAvatar': s.ruRoutmySendCharAvatar,
    'ruRoutmySendUserAvatar': s.ruRoutmySendUserAvatar,
  };

  ImageGenSettings _fromJson(Map<String, dynamic> m) => ImageGenSettings(
    enabled: _castBool(m['enabled'], false),
    apiType: _parseApiType(m['apiType'] as String?),
    useSameEndpoint: _castBool(m['useSameEndpoint'], true),
    customEndpoint: m['customEndpoint'] as String? ?? '',
    customApiKey: m['customApiKey'] as String? ?? '',
    customModel: m['customModel'] as String? ?? '',
    openaiSize: m['openaiSize'] as String? ?? '1024x1024',
    openaiQuality: m['openaiQuality'] as String? ?? 'standard',
    geminiAspectRatio: m['geminiAspectRatio'] as String? ?? '1:1',
    geminiImageSize: m['geminiImageSize'] as String? ?? '1K',
    naisteraApiKey: m['naisteraApiKey'] as String? ?? '',
    naisteraModel: m['naisteraModel'] as String? ?? 'grok',
    naisteraAspectRatio: m['naisteraAspectRatio'] as String? ?? '1:1',
    naisteraSendCharAvatar: _castBool(m['naisteraSendCharAvatar'], false),
    naisteraSendUserAvatar: _castBool(m['naisteraSendUserAvatar'], false),
    routmyApiKey: m['routmyApiKey'] as String? ?? '',
    routmyModel: m['routmyModel'] as String? ?? 'google/gemini-3.1-flash-image-preview',
    routmyAspectRatio: m['routmyAspectRatio'] as String? ?? '1:1',
    routmyImageSize: m['routmyImageSize'] as String? ?? '1K',
    routmyQuality: m['routmyQuality'] as String? ?? 'standard',
    routmySendCharAvatar: _castBool(m['routmySendCharAvatar'], false),
    routmySendUserAvatar: _castBool(m['routmySendUserAvatar'], false),
    imageContextEnabled: _castBool(m['imageContextEnabled'], false),
    imageContextCount: _castInt(m['imageContextCount'], 1),
    additionalReferences: _parseRefs(m['additionalReferences']),
    routmyAdditionalRefs: _parseRefs(m['routmyAdditionalRefs']),
    ruRoutmyApiKey: m['ruRoutmyApiKey'] as String? ?? '',
    ruRoutmyModel: m['ruRoutmyModel'] as String? ?? 'google/gemini-3.1-flash-image-preview',
    ruRoutmyAspectRatio: m['ruRoutmyAspectRatio'] as String? ?? '1:1',
    ruRoutmyImageSize: m['ruRoutmyImageSize'] as String? ?? '1K',
    ruRoutmyQuality: m['ruRoutmyQuality'] as String? ?? 'standard',
    ruRoutmySendCharAvatar: _castBool(m['ruRoutmySendCharAvatar'], false),
    ruRoutmySendUserAvatar: _castBool(m['ruRoutmySendUserAvatar'], false),
  );

  static bool _castBool(dynamic v, bool defaultValue) {
    if (v is bool) return v;
    if (v == 'true') return true;
    if (v == 'false') return false;
    return defaultValue;
  }

  static int _castInt(dynamic v, int defaultValue) {
    if (v is int) return v;
    if (v is String) return int.tryParse(v) ?? defaultValue;
    return defaultValue;
  }

  static ImageGenApiType _parseApiType(String? v) {
    switch (v) {
      case 'gemini': return ImageGenApiType.gemini;
      case 'naistera': return ImageGenApiType.naistera;
      case 'routmy': return ImageGenApiType.routmy;
      case 'ruRoutmy': return ImageGenApiType.ruRoutmy;
      default: return ImageGenApiType.openai;
    }
  }

  static List<ReferenceImage> _parseRefs(dynamic v) {
    if (v is! List) return [];
    return v.map((e) {
      final m = e as Map<String, dynamic>;
      return ReferenceImage(
        name: m['name'] as String? ?? '',
        imageData: m['imageData'] as String? ?? '',
        matchMode: m['matchMode'] as String? ?? 'match',
      );
    }).toList();
  }
}
