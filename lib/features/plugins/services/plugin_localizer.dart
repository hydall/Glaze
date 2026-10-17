import '../models/plugin_manifest.dart';

/// Resolves a plugin's `{ "t": key }` texts against its locale files.
///
/// Fallback chain: requested locale → compatible locales (same
/// language) → `en` → the plugin's `defaultLocale` → the key itself.
class PluginLocalizer {
  PluginLocalizer({
    required this.catalogs,
    required this.defaultLocale,
    required this.requestedLocale,
  }) : chain = _chain(catalogs.keys, requestedLocale, defaultLocale);

  final Map<String, Map<String, String>> catalogs;
  final String? defaultLocale;
  final String requestedLocale;

  /// Catalog tags in lookup order.
  final List<String> chain;

  /// Best single locale for the runtime snapshot.
  String get locale => chain.isNotEmpty ? chain.first : requestedLocale;

  static List<String> _chain(
    Iterable<String> available,
    String requested,
    String? fallback,
  ) {
    final tags = available.toList();
    final out = <String>[];
    void add(String? tag) {
      if (tag != null && tags.contains(tag) && !out.contains(tag)) out.add(tag);
    }

    String lang(String tag) => tag.split('-').first.toLowerCase();
    final want = requested.replaceAll('_', '-');
    add(tags.where((t) => t.toLowerCase() == want.toLowerCase()).firstOrNull);
    for (final t in tags) {
      if (lang(t) == lang(want)) add(t);
    }
    add('en');
    for (final t in tags) {
      if (lang(t) == 'en') add(t);
    }
    add(fallback);
    return out;
  }

  String t(String key) {
    for (final tag in chain) {
      final value = catalogs[tag]?[key];
      if (value != null && value.trim().isNotEmpty) return value;
    }
    return key;
  }

  String resolve(PluginText? text, {String fallback = ''}) {
    if (text == null) return fallback;
    return text.literal ?? t(text.key!);
  }

  /// Flattened catalog for `glaze.plugin.i18n`, lowest priority first so the
  /// preferred locale wins.
  Map<String, Object?> runtimeSnapshot() {
    final messages = <String, String>{};
    for (final tag in chain.reversed) {
      messages.addAll(catalogs[tag] ?? const {});
    }
    return {
      'requestedLocale': requestedLocale,
      'locale': locale,
      'defaultLocale': defaultLocale ?? locale,
      'supportedLocales': catalogs.keys.toList(),
      'messages': messages,
    };
  }
}
