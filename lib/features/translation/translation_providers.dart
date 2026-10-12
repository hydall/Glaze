import 'package:flutter/material.dart';

/// Which engine translates. `llm` runs on a saved API connection; the rest are
/// dedicated machine-translation services reached over their own HTTP APIs.
///
/// Stored as a string in [TranslationSettings.provider] — the ids are persisted,
/// so never rename one; drop an id instead and let the settings fall back to
/// the default.
enum TranslationProvider {
  /// The chat model itself, on a saved connection.
  llm('llm', Icons.smart_toy_outlined),

  /// DeepL.
  deepl('deepl', Icons.translate),

  /// Google Cloud Translation.
  google('google', Icons.g_translate),

  /// Yandex Translate.
  yandex('yandex', Icons.translate),

  /// A self-hosted LibreTranslate instance.
  libretranslate('libretranslate', Icons.dns_outlined);

  final String id;
  final IconData icon;

  const TranslationProvider(this.id, this.icon);

  String get labelKey => 'translation_provider_$id';

  /// True for the providers that authenticate with an API key. A self-hosted
  /// LibreTranslate may run without one, so it is not enforced.
  bool get needsApiKey =>
      this != TranslationProvider.llm &&
      this != TranslationProvider.libretranslate;

  /// Yandex addresses its folder explicitly.
  bool get needsFolderId => this == TranslationProvider.yandex;

  /// The endpoint the provider is called on when the reader has not overridden
  /// it. Empty for [llm], which takes its endpoint from the connection.
  String get defaultEndpoint => switch (this) {
    TranslationProvider.llm => '',
    TranslationProvider.deepl => 'https://api-free.deepl.com/v2/translate',
    TranslationProvider.google =>
      'https://translation.googleapis.com/language/translate/v2',
    TranslationProvider.yandex =>
      'https://translate.api.cloud.yandex.net/translate/v2/translate',
    TranslationProvider.libretranslate => '',
  };

  static TranslationProvider fromId(String? id) {
    for (final provider in values) {
      if (provider.id == id) return provider;
    }
    return TranslationProvider.llm;
  }
}
