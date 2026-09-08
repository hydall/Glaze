import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

Future<void> writeImgGenPrefs(
    Map<String, dynamic>? profile, bool useSameAsLlm) async {
  if (profile == null) return;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('gz_imggen_use_same', useSameAsLlm);
  if (!useSameAsLlm) {
    await prefs.setString(
        'gz_imggen_endpoint', profile['endpoint'] as String? ?? '');
    await prefs.setString('gz_imggen_api_key',
        profile['apiKey'] as String? ?? profile['key'] as String? ?? '');
    await prefs.setString(
        'gz_imggen_model', profile['model'] as String? ?? '');
  }
}

Future<void> writeMemoryBooksPrefs(
    Map<String, dynamic>? profile, bool useSameAsLlm) async {
  if (profile == null) return;
  final prefs = await SharedPreferences.getInstance();
  final memSettings = <String, dynamic>{};
  final existing = prefs.getString('memorySettings');
  if (existing != null) {
    try {
      memSettings.addAll(jsonDecode(existing) as Map<String, dynamic>);
    } catch (_) {}
  }
  if (useSameAsLlm) {
    memSettings['generationSource'] = 'current';
    memSettings['generationUseCurrentModelOverride'] = true;
    memSettings['generationEndpoint'] = '';
    memSettings['generationApiKey'] = '';
    memSettings['generationModel'] = '';
  } else {
    memSettings['generationSource'] = 'custom';
    memSettings['generationUseCurrentModelOverride'] = false;
    memSettings['generationEndpoint'] = profile['endpoint'] as String? ?? '';
    memSettings['generationApiKey'] =
        profile['apiKey'] as String? ?? profile['key'] as String? ?? '';
    memSettings['generationModel'] = profile['model'] as String? ?? '';
  }
  await prefs.setString('memorySettings', jsonEncode(memSettings));
}
