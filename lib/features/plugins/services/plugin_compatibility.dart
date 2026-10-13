import 'dart:convert';

import 'plugin_package_reader.dart';

/// Features a plugin may rely on that Glaze does not provide.
enum UnsupportedPluginFeature { tts }

final _ttsCall = RegExp(r'\b(?:tavo|glaze)\s*\.\s*tts\b');

/// What in [package] will not work in Glaze: a `tts` permission, or a script
/// that calls the text-to-speech API.
Set<UnsupportedPluginFeature> unsupportedPluginFeatures(PluginPackage package) {
  if (package.manifest.hasPermission('tts')) {
    return {UnsupportedPluginFeature.tts};
  }
  for (final entry in package.files.entries) {
    final name = entry.key.toLowerCase();
    if (!name.endsWith('.js') && !name.endsWith('.html')) continue;
    final source = utf8.decode(entry.value, allowMalformed: true);
    if (_ttsCall.hasMatch(source)) return {UnsupportedPluginFeature.tts};
  }
  return const {};
}
